const fs = require("node:fs");
let forgeLcovFile = fs.readFileSync("lcov.info", "utf8");
let prunedForgeLcovPath = "lcov.info.pruned";
if (fs.existsSync(prunedForgeLcovPath)) {
  fs.unlinkSync(prunedForgeLcovPath);
}

let del = false;
for (let line of forgeLcovFile.split("\n")) {
  if (
    line.includes("test/mock/") ||
    line.includes("contracts/mock") ||
    line.includes("test/utils/") ||
    // Deploy scripts are tooling, not deployed protocol code. Only the ones a test happens to
    // subclass reach the report at all, so the figure moved with which harness existed rather
    // than with deploy-script quality - and adding one lowered it. They keep their test suites.
    line.includes("deployment/")
  ) {
    del = true;
  } else if (line.includes("end_of_record") && del) {
    del = false;
  } else if (!del) {
    fs.appendFileSync(prunedForgeLcovPath, line + "\n");
  }
}
