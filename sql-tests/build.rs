extern crate build_deps;

/// This build.rs ensures that the tests are recompiled when new test cases are
/// added to the `testdata` directory.
fn main() {
    build_deps::rerun_if_changed_paths("testdata/*.sql").unwrap();
    build_deps::rerun_if_changed_paths("testdata").unwrap();
}
