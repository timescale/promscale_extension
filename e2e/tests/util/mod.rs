use log::debug;

pub fn debug_lines(stdout: Vec<u8>) {
    String::from_utf8(stdout).unwrap().lines().for_each(|line| {
        debug!("{}", line);
    })
}
