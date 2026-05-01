const fs = require("fs");
const path = require("path");

const outDir = path.join(__dirname, "..", "programs");

function checkReg(x) {
  if (x < 0 || x > 31) throw new Error(`bad register ${x}`);
}

function signed(value, bits) {
  const min = -(2 ** (bits - 1));
  const max = (2 ** (bits - 1)) - 1;
  if (value < min || value > max) throw new Error(`Immediate ${value} does not fit ${bits}`);
  return value & ((2 ** bits) - 1);
}

function r(funct7, rs2, rs1, funct3, rd, opcode) {
  [rs2, rs1, rd].forEach(checkReg);
  return ((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) >>> 0;
}

function i(imm, rs1, funct3, rd, opcode) {
  checkReg(rs1); checkReg(rd);
  const u = signed(imm, 12);
  return ((u << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) >>> 0;
}

function s(imm, rs2, rs1, funct3, opcode) {
  checkReg(rs2); checkReg(rs1);
  const u = signed(imm, 12);
  return ((((u >>> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((u & 0x1f) << 7) | opcode) >>> 0;
}

function b(offset, rs2, rs1, funct3, opcode) {
  checkReg(rs2); checkReg(rs1);
  if (offset % 2 !== 0) throw new Error(`branch offset ${offset}`);
  const u = signed(offset, 13);
  return ((((u >>> 12) & 1) << 31) | (((u >>> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) |
    (funct3 << 12) | (((u >>> 1) & 0xf) << 8) | (((u >>> 11) & 1) << 7) | opcode) >>> 0;
}

function j(offset, rd, opcode) {
  checkReg(rd);
  if (offset % 2 !== 0) throw new Error(`jump offset ${offset}`);
  const u = offset & 0x1fffff;
  return ((((u >>> 20) & 1) << 31) | (((u >>> 1) & 0x3ff) << 21) | (((u >>> 11) & 1) << 20) |
    (((u >>> 12) & 0xff) << 12) | (rd << 7) | opcode) >>> 0;
}

function csr(csrAddr, rs1, funct3, rd) {
  return i(csrAddr, rs1, funct3, rd, 0x73);
}

const labels = {};
const program = [];

function pc() { return program.length * 4; }
function label(name) { labels[name] = pc(); }
function emit(text, encode) { program.push({ text, encode }); }
function org(addr) {
  while (pc() < addr) emit("nop", () => i(0, 0, 0, 0, 0x13));
  if (pc() !== addr) throw new Error(`org 0x${addr.toString(16)} not aligned`);
}

const CSR_MSTATUS = 0x300;
const CSR_MIE = 0x304;
const CSR_MTVEC = 0x305;
const CSR_MEPC = 0x341;
const CSR_MCAUSE = 0x342;
const CSR_MTVAL = 0x343;
const CSR_PMPBASE0 = 0x7c0;

emit("addi x1, x0, trap_vector", () => i(labels.trap_vector, 0, 0, 1, 0x13));
emit("csrw mtvec, x1", () => csr(CSR_MTVEC, 1, 0b001, 0));
emit("addi x1, x0, 128", () => i(128, 0, 0, 1, 0x13));
emit("csrw mie, x1", () => csr(CSR_MIE, 1, 0b001, 0));
emit("addi x1, x0, 8", () => i(8, 0, 0, 1, 0x13));
emit("csrs mstatus, x1", () => csr(CSR_MSTATUS, 1, 0b010, 0));
label("wait_irq");
emit("lw x2, 772(x0)", () => i(772, 0, 0b010, 2, 0x03));
emit("beq x2, x0, wait_irq", here => b(labels.wait_irq - here, 0, 2, 0b000, 0x63));
emit("addi x1, x0, 8", () => i(8, 0, 0, 1, 0x13));
emit("csrc mstatus, x1", () => csr(CSR_MSTATUS, 1, 0b011, 0));
emit("csrr x5, pmpbase0", () => csr(CSR_PMPBASE0, 0, 0b010, 5));
emit("addi x6, x0, 291", () => i(291, 0, 0, 6, 0x13));
emit("csrw pmpbase0, x6", () => csr(CSR_PMPBASE0, 6, 0b001, 0));
emit("csrr x7, pmpbase0", () => csr(CSR_PMPBASE0, 0, 0b010, 7));
emit("bne x5, x7, fail", here => b(labels.fail - here, 7, 5, 0b001, 0x63));
emit("jal x0, enter_user", here => j(labels.enter_user - here, 0, 0x6f));

org(0x40);
label("trap_vector");
emit("csrr x10, mcause", () => csr(CSR_MCAUSE, 0, 0b010, 10));
emit("lui x11, 0x80000", () => (0x80000 << 12) | (11 << 7) | 0x37);
emit("addi x11, x11, 7", () => i(7, 11, 0, 11, 0x13));
emit("beq x10, x11, handle_timer", here => b(labels.handle_timer - here, 11, 10, 0b000, 0x63));
emit("addi x11, x0, 7", () => i(7, 0, 0, 11, 0x13));
emit("beq x10, x11, handle_store_fault", here => b(labels.handle_store_fault - here, 11, 10, 0b000, 0x63));
emit("addi x11, x0, 8", () => i(8, 0, 0, 11, 0x13));
emit("beq x10, x11, handle_ecall", here => b(labels.handle_ecall - here, 11, 10, 0b000, 0x63));
emit("jal x0, fail", here => j(labels.fail - here, 0, 0x6f));
label("handle_timer");
emit("addi x12, x0, 1", () => i(1, 0, 0, 12, 0x13));
emit("sw x12, 772(x0)", () => s(772, 12, 0, 0b010, 0x23));
emit("mret", () => 0x30200073);
label("handle_store_fault");
emit("csrr x13, mtval", () => csr(CSR_MTVAL, 0, 0b010, 13));
emit("bne x13, x0, fail", here => b(labels.fail - here, 0, 13, 0b001, 0x63));
emit("addi x14, x0, after_fault", () => i(labels.after_fault, 0, 0, 14, 0x13));
emit("csrw mepc, x14", () => csr(CSR_MEPC, 14, 0b001, 0));
emit("mret", () => 0x30200073);
label("handle_ecall");
emit("addi x15, x0, 1", () => i(1, 0, 0, 15, 0x13));
emit("sw x15, 768(x0)", () => s(768, 15, 0, 0b010, 0x23));
emit("jal x0, halt", here => j(labels.halt - here, 0, 0x6f));

label("enter_user");
emit("addi x1, x0, user_start", () => i(labels.user_start, 0, 0, 1, 0x13));
emit("csrw mepc, x1", () => csr(CSR_MEPC, 1, 0b001, 0));
emit("mret", () => 0x30200073);

label("fail");
emit("addi x31, x0, -1", () => i(-1, 0, 0, 31, 0x13));
emit("sw x31, 768(x0)", () => s(768, 31, 0, 0b010, 0x23));
label("halt");
emit("jal x0, halt", here => j(labels.halt - here, 0, 0x6f));

org(0x100);
label("user_start");
emit("addi x2, x0, 7", () => i(7, 0, 0, 2, 0x13));
emit("sw x2, 512(x0)", () => s(512, 2, 0, 0b010, 0x23));
emit("lw x3, 512(x0)", () => i(512, 0, 0b010, 3, 0x03));
emit("bne x2, x3, user_fail", here => b(labels.user_fail - here, 3, 2, 0b001, 0x63));
emit("sw x2, 0(x0)", () => s(0, 2, 0, 0b010, 0x23));
label("after_fault");
emit("ecall", () => 0x00000073);
label("user_fail");
emit("addi x31, x0, -9", () => i(-9, 0, 0, 31, 0x13));
emit("ecall", () => 0x00000073);

const words = program.map((entry, index) => entry.encode(index * 4) >>> 0);
while (words.length < 256) words.push(0x00000013);

const hex = words.map(word => word.toString(16).padStart(8, "0")).join("\n") + "\n";
const listing = program.map((entry, index) => {
  const addr = (index * 4).toString(16).padStart(8, "0");
  const word = words[index].toString(16).padStart(8, "0");
  const names = Object.entries(labels).filter(([, v]) => v === index * 4).map(([k]) => `<${k}> `).join("");
  return `${addr}: ${word}    ${names}${entry.text}`;
}).join("\n") + "\n";

fs.writeFileSync(path.join(outDir, "secure.hex"), hex);
fs.writeFileSync(path.join(outDir, "secure.list"), listing);
console.log(`Wrote secure MCU program: ${program.length} instructions, ${words.length} hex words`);
