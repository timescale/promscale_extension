use hex;
use md5::{Digest, Md5};
use std::path::PathBuf;
use std::{env, fs};

/// Ensures that released incremental migrations scripts are not modified.
#[test]
fn incremental_freeze_test() {
    let _ = pretty_env_logger::try_init();

    // The sql scripts in migration/incremental/ are not idempotent. They are meant to be run once
    // and only once on any given promscale installation. We track whether or not these files have
    // been applied in the _ps_catalog.migration table. Once we have released a version of
    // promscale, all the incremental scripts are considered frozen. They have been applied to
    // databases in the wild, and we don't want to create a situation in which some databases were
    // created using one version of a script, while others used a different version.
    // This test is meant to keep us from accidentally changing an incremental file after it has
    // been released. When cutting a new release, append to the list of files below the filenames
    // and MD5 hashes of all the new files going out with that release.
    let incremental_dir = PathBuf::new()
        .join(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../migration/incremental");

    let frozen_files = [
        // ↓↓↓ frozen in 0.5.0 ↓↓↓
        ("001-extension.sql", "66dd9ae5e47b32fe93af380e8dc107e2"),
        ("002-utils.sql", "2450a0291c64f48e80bd4d4638f3bba0"),
        ("003-users.sql", "ca921c533531d5715bfeb688f569325f"),
        ("004-schemas.sql", "f2785b92611bd621c8fb64f2a5403b47"),
        ("005-tag-operators.sql", "93025aa25ca16e8d9902bf48cda2e77c"),
        ("006-tables.sql", "706234b562dc5eb3649474b2869f271c"),
        (
            "007-matcher-operators.sql",
            "a3905324b05dbb6d46ba76ac43da0ca0",
        ),
        ("008-install-uda.sql", "b3fcd9187382028987bac0f64678e849"),
        ("009-tables-ha.sql", "fc7c60b8e911ce454961690d8a30c610"),
        (
            "010-tables-metadata.sql",
            "69d8b3e2a587078dbc71a17d7cedbf65",
        ),
        (
            "011-tables-exemplar.sql",
            "9036070888f0cc3d8e545a479d864d28",
        ),
        ("012-tracing.sql", "fd639f016094c370f368c5c4358e935a"),
        (
            "013-tracing-well-known-tags.sql",
            "f6dafc2ddc0c5e2db32fcdce5c67a193",
        ),
        ("014-telemetry.sql", "69eb61e653d23a37ecdbe0d8f24deb99"),
        (
            "015-tracing-redesign.sql",
            "485e1d3aa79be276ae5867e9eff0482e",
        ),
        (
            "016-remove-ee-schemas.sql",
            "0409432e7261233f2626ea0d0389a6de",
        ),
        (
            "017-set-search-path.sql",
            "3fd771a6ae751bc55deab6014b6ccdda",
        ),
        (
            "018-grant-prom-roles.sql",
            "bcd9b321566bab2af3354df595405536",
        ),
        (
            "019-prom-installation-info.sql",
            "23910dee4eb761c86985b1d656b0860a",
        ),
        (
            "020-series-partitions.sql",
            "ff05bb62a8a4ddfb459ec4a720476f5b",
        ),
        (
            "021-initial-default.sql",
            "be4e6f023382878d432ac9438cb0e407",
        ),
        ("022-jit-off.sql", "4ebda0b60a31332cad5f0b8fb2d05d7c"),
        ("023-privileges.sql", "7a810fe5538653ce6e06674dbbdf7451"),
        (
            "024-adjust_autovacuum.sql",
            "0fe28659efa74be9663cc158f84294cb",
        ),
        // ↓↓↓ frozen in 0.5.2 ↓↓↓
        (
            "025-tag-map-storage-type.sql",
            "864f4e138ff04bc835d82f1bf5168f0e",
        ),
        (
            "026-remove-name-param.sql",
            "6a824c25362765c61f58165db8651700",
        ),
        (
            "027-tag-map-storage-views.sql",
            "d3c1772e6da5deaa49e3fa2fb09b03c6",
        ),
        // ↓↓↓ frozen in 0.5.3 ↓↓↓
        (
            "028-refactor-mark-unused-series.sql",
            "3196b67a651569d33eacb9e3c2bd908c",
        ),
        (
            "029-remove-unused-ingest-func.sql",
            "a42d08b7425c11efe492dc6c70031781",
        ),
        // ↓↓↓ frozen in x.x.x ↓↓↓
    ];
    for (filename, expected) in frozen_files {
        let body = fs::read_to_string(incremental_dir.join(filename)).expect("failed to read file");
        let mut hasher = Md5::new();
        hasher.update(body);
        let actual = hex::encode(hasher.finalize());
        assert_eq!(
            actual, expected,
            "migration/incremental/{} is frozen but appears to have been modified",
            filename
        );
    }
}
