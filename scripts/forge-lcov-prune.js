const fs = require("node:fs");
let forgeLcovFile = fs.readFileSync('lcov.info', 'utf8');
let prunedForgeLcovPath = 'lcov.info.pruned';
if (fs.existsSync(prunedForgeLcovPath)) {
  fs.unlinkSync(prunedForgeLcovPath);
}

let del = false;
for (let line of forgeLcovFile.split('\n')) {
  if (
    line.includes('test/mock/') ||
    line.includes('contracts/mock') ||
    line.includes('test/utils/')) {
    del = true;
  } else if (line.includes('end_of_record') && del) {
    del = false;
  } else if (!del) {
    fs.appendFileSync(prunedForgeLcovPath, line + '\n');
  }
}

