use std::{
    env,
    fs::{self, File},
    io::{BufRead, BufReader, BufWriter, Write},
    path::{Path, PathBuf},
    process,
};

use xshell::cmd;

mod update_script;

macro_rules! path {
    ($start:ident $(/ $segment: literal)*) => {
        {
            let root: &Path = $start.as_ref();
            root $(.join($segment))*
        }
    };
    ($start:ident / $segment: expr) => {
        {
            let root: &Path = $start.as_ref();
            root.join($segment)
        }
    }
}

fn main() {
    if let Err(err) = try_main() {
        eprintln!("{}", err);
        process::exit(1);
    }
}

fn try_main() -> xshell::Result<()> {
    let pg_config = env::args().nth(1).expect("missing /path/to/pg_config");
    let extension_info = if pg_config == "--dir" {
        let package_dir = env::args().nth(2).expect("missing /path/to/package_dir");
        get_extension_info_from_dir(&package_dir)?
    } else {
        get_extension_info_from_pg_config(&pg_config)?
    };

    // remove `module_path = '$libdir/promscale'`
    // from promscale.control.
    // Not needed for correctness purposes, but it ensures that if `MODULE_PATH`
    // is left anywhere in the install script, it will fail to install.
    remove_module_path_from_control_file(&extension_info);

    // replace `MODULE_PATH` with `$libdir/promscale-<current version>`
    add_version_to_install_script(&extension_info);

    generate_update_scripts(&extension_info);

    Ok(())
}

struct ExtensionInfo {
    control_file: PathBuf,
    current_version: String,
    upgradeable_from: Vec<String>,
    extension_dir: PathBuf,
}

fn get_extension_info_from_pg_config(pg_config: &str) -> xshell::Result<ExtensionInfo> {
    let share_dir = cmd!("{pg_config} --sharedir").read()?;
    let extension_dir = path!(share_dir / "extension");
    let control_file = path!(extension_dir / "promscale.control");

    let control_contents = fs::read_to_string(&control_file).unwrap_or_else(|e| {
        panic!(
            "cannot read control file {} due to {}",
            control_file.to_string_lossy(),
            e,
        )
    });

    let current_version = get_current_version(&control_contents);
    eprintln!("Generating Version {}", current_version);

    let upgradeable_from = get_upgradeable_from(&control_contents);
    eprintln!("Upgradable From {:?}", upgradeable_from);

    let extension_info = ExtensionInfo {
        control_file,
        current_version,
        upgradeable_from,
        extension_dir,
    };
    Ok(extension_info)
}

fn get_extension_info_from_dir(root: &str) -> xshell::Result<ExtensionInfo> {
    use std::ffi::OsStr;
    use walkdir::{DirEntry, WalkDir};

    fn is_control(entry: &DirEntry) -> bool {
        entry.file_type().is_file() && entry.path().extension() == Some(OsStr::new("control"))
    }

    fn is_dir_or_control(entry: &DirEntry) -> bool {
        entry.file_type().is_dir() || is_control(entry)
    }

    let walker = WalkDir::new(root).contents_first(true);

    let (extension_dir, control_file) = walker
        .into_iter()
        .filter_entry(is_dir_or_control)
        .find_map(|e| e.ok().filter(is_control).map(|e| e.into_path()))
        .map(|path| {
            let dir = path
                .parent()
                .expect("control file not in dir")
                .to_path_buf();
            (dir, path)
        })
        .expect("could not find extension objects");

    let control_contents = fs::read_to_string(&control_file).unwrap_or_else(|e| {
        panic!(
            "cannot read control file {} due to {}",
            control_file.to_string_lossy(),
            e,
        )
    });

    let current_version = get_current_version(&control_contents);
    eprintln!("Generating Version {}", current_version);

    let upgradeable_from = get_upgradeable_from(&control_contents);
    eprintln!("Upgradable From {:?}", upgradeable_from);

    Ok(ExtensionInfo {
        control_file,
        current_version,
        upgradeable_from,
        extension_dir,
    })
}

fn get_current_version(control_contents: &str) -> String {
    get_field_val(control_contents, "default_version").to_string()
}

fn get_upgradeable_from(control_contents: &str) -> Vec<String> {
    // versions is a comma-delimited list of versions
    let versions = get_field_val(control_contents, "upgradeable_from");
    versions
        .split_terminator(',')
        .map(|version| version.trim().to_string())
        .collect()
}

fn remove_module_path_from_control_file(ExtensionInfo { control_file, .. }: &ExtensionInfo) {
    let tmp_file = control_file.with_extension("control.tmp");
    transform_file_to(control_file, &tmp_file, |line| {
        if line.starts_with("module_pathname") {
            return "".to_string();
        }

        line
    });
    rename_file(tmp_file, control_file);
}

fn add_version_to_install_script(
    ExtensionInfo {
        current_version,
        extension_dir,
        ..
    }: &ExtensionInfo,
) {
    let install_script = path!(extension_dir / format!("promscale--{}.sql", current_version));

    let versioned_script = install_script.with_extension("sql.tmp");

    let module_path = format!("$libdir/promscale-{}", current_version);

    transform_file_to(&install_script, &versioned_script, |line| {
        if line.contains("MODULE_PATHNAME") {
            return line.replace("MODULE_PATHNAME", &module_path);
        }
        line
    });

    rename_file(&versioned_script, &install_script);
}

//
// upgrade scripts
//

fn generate_update_scripts(
    ExtensionInfo {
        current_version,
        upgradeable_from,
        extension_dir,
        ..
    }: &ExtensionInfo,
) {
    let extension_path = path!(extension_dir / format!("promscale--{}.sql", current_version));

    for from_version in upgradeable_from {
        let mut extension_file = open_file(&extension_path);

        let upgrade_path = path!(
            extension_dir
                / format!(
                    "promscale--{from}--{to}.sql",
                    from = from_version,
                    to = current_version
                )
        );
        let mut upgrade_file = create_file(&upgrade_path);

        update_script::generate_from_install(&mut extension_file, &mut upgrade_file);

        copy_permissions(extension_file, upgrade_file);
    }
}

trait PushLine {
    fn push_line(&mut self, line: &str);
}

impl PushLine for String {
    fn push_line(&mut self, line: &str) {
        self.push_str(line);
        self.push('\n');
    }
}

//
// control file utils
//

// find a `<field name> = '<field value>'` and extract `<field value>`
fn get_field_val<'a>(contents: &'a str, field: &str) -> &'a str {
    contents
        .lines()
        .filter(|line| line.contains(field))
        .map(get_quoted_field)
        .next()
        .unwrap_or_else(|| panic!("cannot read field `{}` in control file", field))
}

// given a `<field name> = '<field value>'` extract `<field value>`
fn get_quoted_field(line: &str) -> &str {
    let quoted = line
        .split('=')
        .nth(1)
        .unwrap_or_else(|| panic!("cannot find value in line `{}`", line));

    quoted
        .trim_start()
        .split_terminator('\'')
        .find(|s| !s.is_empty())
        .unwrap_or_else(|| panic!("unquoted value in line `{}`", line))
}

//
// file utils
//

fn open_file(path: impl AsRef<Path>) -> BufReader<File> {
    let path = path.as_ref();
    let file = File::open(&path)
        .unwrap_or_else(|e| panic!("cannot open file `{}` due to {}", path.to_string_lossy(), e,));
    BufReader::new(file)
}

fn create_file(path: impl AsRef<Path>) -> BufWriter<File> {
    let path = path.as_ref();
    let file = File::create(path).unwrap_or_else(|e| {
        panic!(
            "cannot create file `{}` due to {}",
            path.to_string_lossy(),
            e,
        )
    });
    BufWriter::new(file)
}

fn rename_file(from: impl AsRef<Path>, to: impl AsRef<Path>) {
    let from = from.as_ref();
    let to = to.as_ref();
    fs::rename(from, to).unwrap_or_else(|e| {
        panic!(
            "cannot rename `{}` to `{}` due to `{}`",
            from.to_string_lossy(),
            to.to_string_lossy(),
            e,
        )
    });
}

fn transform_file_to(
    from: impl AsRef<Path>,
    to: impl AsRef<Path>,
    mut transform: impl FnMut(String) -> String,
) {
    let to_path = to.as_ref();
    let mut to = create_file(to_path);
    let from_path = from.as_ref();
    let mut from = open_file(from_path);

    for line in (&mut from).lines() {
        let line = line.unwrap_or_else(|e| {
            panic!("cannot read `{}` due to {}", from_path.to_string_lossy(), e,)
        });

        writeln!(&mut to, "{}", transform(line)).unwrap_or_else(|e| {
            panic!(
                "cannot write to `{}` due to {}",
                to_path.to_string_lossy(),
                e,
            )
        });
    }

    copy_permissions(from, to);
}

fn copy_permissions(from: BufReader<File>, to: BufWriter<File>) {
    let permissions = from.into_inner().metadata().unwrap().permissions();
    to.into_inner()
        .unwrap()
        .set_permissions(permissions)
        .unwrap();
}
