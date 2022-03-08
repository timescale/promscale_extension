extern crate build_deps;

fn main() {
    build_deps::rerun_if_changed_paths("testdata/*.sql").unwrap();
    build_deps::rerun_if_changed_paths("testdata").unwrap();
}
