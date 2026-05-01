const fs = require("fs");
const path = require("path");
const outDir = path.join(__dirname, "..", "programs");

function i(imm, rs1, funct3, rd, opcode) {
  const u = imm & 0xfff;
  return ((u << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) >>> 0;
}
function s(imm, rs2, rs1, funct3, opcode) {
  const u = imm & 0xfff;
  return ((((u >>> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((u & 0x1f) << 7) | opcode) >>> 0;
}
function j(offset, rd) {
  const u = offset & 0x1fffff;
  return ((((u >>> 20) & 1) << 31) | (((u >>> 1) & 0x3ff) << 21) | (((u >>> 11) & 1) << 20) |
    (((u >>> 12) & 0xff) << 12) | (rd << 7) | 0x6f) >>> 0;
}

const program = [];
function emit(text, word) { program.push({ text, word: word >>> 0 }); }

emit("addi x5, x0, 0", i(0, 0, 0, 5, 0x13));
for (let n = 0; n < 96; n++) {
  emit(`addi x5, x5, 1`, i(1, 5, 0, 5, 0x13));
}
emit("sw x5, 256(x0)", s(256, 5, 0, 0b010, 0x23));
emit("lw x6, 256(x0)", i(256, 0, 0b010, 6, 0x03));
emit("jal x0, halt", j(0, 0));

const words = program.map(x => x.word);
while (words.length < 512) words.push(0x00000013);

fs.writeFileSync(path.join(outDir, "perf.hex"), words.map(w => w.toString(16).padStart(8, "0")).join("\n") + "\n");
fs.writeFileSync(path.join(outDir, "perf.list"), program.map((x, idx) => `${(idx*4).toString(16).padStart(8,"0")}: ${x.word.toString(16).padStart(8,"0")}    ${idx === program.length - 1 ? "<halt> " : ""}${x.text}`).join("\n") + "\n");
console.log(`Wrote perf benchmark: ${program.length} instructions`);
