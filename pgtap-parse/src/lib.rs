use crate::TestResult::{FAIL, PASS};
use regex::Regex;

#[cfg(not(test))]
use log::debug; // Use log crate when building application

#[cfg(test)]
use std::println as debug; // Workaround to use prinltn! for logs.

#[derive(Debug, PartialOrd, PartialEq)]
pub struct PgTapResult {
    pub planned_test_count: usize,
    pub executed_test_count: usize,
    pub success_count: usize,
    pub test_results: Vec<PgTapTest>,
}

#[derive(Debug, PartialOrd, PartialEq)]
pub struct PgTapTest {
    pub test_name: String,
    pub test_result: TestResult,
}

#[derive(Clone, Debug, PartialOrd, PartialEq)]
pub enum TestResult {
    PASS,
    FAIL,
}

/// Parses the output of a pgtap run. Returns None if no pgtap output detected
/// in `pgtap_output`.
/// Note: This does not handle subtest results, and assumes that if one subtest
/// fails, the "parent" test will fail too.
pub fn parse_pgtap_result(pgtap_output: &str) -> Option<PgTapResult> {
    let mut planned_test_count: Option<usize> = None;

    // A pgtap plan consists of:
    // - some leading whitespace
    // - nesting in groups of four spaces, for subtests
    // - the start test number, usually 1
    // - two dots
    // - the end test number
    let plan_re = Regex::new(r".*?(?P<nesting>\s{4})*(?P<start>\d+)\.\.(?P<end>\d+)").unwrap();

    // A pgtap result consists of:
    // - some leading whitespace
    // - nesting in groups of four spaces, for subtests
    // - a result
    // - the test number
    // - separator
    // - optionally: the test name
    let result_re = Regex::new(
        r"^.*?(?P<nesting>\s{4})*(?P<result>not ok|ok) (?P<number>\d+)( - )?(?P<name>.*)$",
    )
    .unwrap();

    let mut test_results: Vec<PgTapTest> = Vec::new();

    for line in pgtap_output.lines() {
        debug!("\t\tinspecting line: '{}'", line);

        if let Some(captures) = plan_re.captures(&line) {
            let nesting = captures.name("nesting").map_or(0, |s| s.as_str().len() / 4);
            debug!("Nesting level is: {}", nesting);
            if nesting > 0 {
                // We don't support interpreting subtests, so just skip
                continue;
            }

            planned_test_count = Some(captures.name("end").unwrap().as_str().parse().unwrap());
            debug!("There are {} planned tests", planned_test_count.unwrap());
        } else {
            // split the input line on a table boundary, this handles the case
            // where multiple pg_tap results are returned in one query
            for subline in line.split(" | ") {
                // count each occurrence of "ok \d+" or "not ok \d+"
                if let Some(captures) = result_re.captures(&subline) {
                    let nesting = captures.name("nesting").map_or(0, |s| s.as_str().len() / 4);
                    debug!("Nesting level is: {}", nesting);
                    if nesting > 0 {
                        // We don't support interpreting subtests, so just skip
                        continue;
                    }

                    let test_result = match captures.name("result").unwrap().as_str() {
                        "ok" => PASS,
                        "not ok" => FAIL,
                        _ => todo!(),
                    };
                    let test_name = captures.name("name").unwrap().as_str().to_string();
                    test_results.push(PgTapTest {
                        test_name,
                        test_result: test_result.clone(),
                    });
                }
            }
        }
    }

    planned_test_count.map(|planned_test_count| {
        let success_count = test_results
            .iter()
            .filter(|r| r.test_result == PASS)
            .count();
        PgTapResult {
            planned_test_count: planned_test_count,
            executed_test_count: test_results.len(),
            success_count,
            test_results,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn given_no_pgtap_input_it_returns_null() {
        let result = parse_pgtap_result("");
        assert!(result.is_none());
    }

    #[test]
    fn given_pgtap_success_it_returns_success() {
        let result = parse_pgtap_result(
            r#"
 plan
-------
 1..1
(1 row)

                  ok
---------------------------------------
 ok 1 - none of the chunks are deleted
(1 row)
        "#,
        );
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 1,
                executed_test_count: 1,
                success_count: 1,
                test_results: vec!(PgTapTest {
                    test_name: String::from("none of the chunks are deleted"),
                    test_result: PASS
                })
            }
        );
    }

    #[test]
    fn given_pgtap_success_no_test_name_it_returns_success() {
        let result = parse_pgtap_result(
            r#"
 plan
-------
 1..1
(1 row)

                  ok
---------------------------------------
 ok 1
(1 row)
        "#,
        );
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 1,
                executed_test_count: 1,
                success_count: 1,
                test_results: vec!(PgTapTest {
                    test_name: String::from(""),
                    test_result: PASS
                })
            }
        );
    }

    #[test]
    fn given_pgtap_failure_it_returns_failure() {
        let input = r#"
 plan
-------
 1..1
(1 row)

                  ok
---------------------------------------
 not ok 1 - none of the chunks are deleted
(1 row)
        "#;
        let result = parse_pgtap_result(input);
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 1,
                executed_test_count: 1,
                success_count: 0,
                test_results: vec!(PgTapTest {
                    test_name: String::from("none of the chunks are deleted"),
                    test_result: FAIL
                })
            }
        );
    }

    #[test]
    fn given_pgtap_missing_test_it_returns_failure() {
        let input = r#"
 plan
-------
 1..1
(1 row)
        "#;
        let result = parse_pgtap_result(input);
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 1,
                executed_test_count: 0,
                success_count: 0,
                test_results: vec!()
            }
        );
    }

    #[test]
    fn given_pgtap_test_count_after_results_it_parses_correctly() {
        let input = r#"
 plan
-------
 ok 1 - public.test_create_ingest_temp_table
 1..1
(2 rows)
        "#;
        let result = parse_pgtap_result(input);
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 1,
                executed_test_count: 1,
                success_count: 1,
                test_results: vec!(PgTapTest {
                    test_name: String::from("public.test_create_ingest_temp_table"),
                    test_result: PASS
                })
            }
        );
    }

    #[test]
    fn given_pgtap_subtest_it_parses_correctly() {
        let input = r#"
                                               runtests
------------------------------------------------------------------------------------------------------
     # Subtest: subtest_one()
     ok 1 - subtest one test one
     ok 2 - subtest one test two
     1..2
     # Subtest: subtest_two()
     ok 1 - subtest two test one
     1..1
 ok 1 - subtest_one()
 ok 2 - subtest_two()
 1..2
(10 rows)
        "#;
        let result = parse_pgtap_result(input);
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 2,
                executed_test_count: 2,
                success_count: 2,
                test_results: vec!(
                    PgTapTest {
                        test_name: String::from("subtest_one()"),
                        test_result: PASS
                    },
                    PgTapTest {
                        test_name: String::from("subtest_two()"),
                        test_result: PASS
                    }
                )
            }
        );
    }

    #[test]
    fn given_pgtap_output_contains_multiple_results_per_line() {
        let input = r#"
 plan
-------
 1..2
(1 row)
           ok           |        ok
------------------------+-------------------
 ok 8 - subplan is used | ok 9 - uses index
(1 row)
"#;
        let result = parse_pgtap_result(input);
        assert_eq!(
            result.unwrap(),
            PgTapResult {
                planned_test_count: 2,
                executed_test_count: 2,
                success_count: 2,
                test_results: vec!(
                    PgTapTest {
                        test_name: String::from("subplan is used"),
                        test_result: PASS
                    },
                    PgTapTest {
                        test_name: String::from("uses index"),
                        test_result: PASS
                    }
                )
            }
        );
    }
}
