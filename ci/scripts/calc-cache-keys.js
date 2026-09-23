module.exports = async ({ os, plan, path, core, glob }) => {
  function build_keys(comps) {
    const fallbacks = comps
      .reduce((accum, cur) => [accum[0].concat([cur])].concat(accum), [[]])
      .slice(1, -1)
      .map((e) => e.concat("").join("-"));

    return { key: comps.join("-"), restore: fallbacks.join("\n") };
  }
  // @actions/glob's hashFiles takes one pattern string, patterns separated by
  // newlines; a second argument is the workspace, not another pattern, and
  // would make every file fall outside it and the hash come out empty.
  const hash = (patterns) =>
    glob.hashFiles(patterns.concat(["!dist-newstyle/**"]).join("\n"));

  const project_hash = await hash([path]);
  core.setOutput("project", project_hash);

  const package_hash = await hash(["**/*.cabal"]);
  core.setOutput("package", package_hash);

  const source_hash = await hash([
    "**/*.hs",
    "**/*.lhs",
    "**/*.hsig",
    "**/*.hs-boot",
    "**/*.c",
    "**/*.h",
    "**/*.chs",
    "**/*.hsc",
  ]);
  core.setOutput("source", source_hash);

  const store_prefix = `store-${os}-${plan}`;
  core.setOutput("store-prefix", store_prefix);
  const store_keys = build_keys([store_prefix, project_hash, package_hash]);
  core.setOutput("store", store_keys.key);
  core.setOutput("store-restore", store_keys.restore);

  const dist_prefix = `dist-${os}-${plan}`;
  core.setOutput("dist-prefix", dist_prefix);
  const dist_key_comps = [dist_prefix, project_hash, package_hash, source_hash];
  const dist_keys = build_keys(dist_key_comps);
  core.setOutput("dist", dist_keys.key);
  core.setOutput("dist-restore", dist_keys.restore);
};
