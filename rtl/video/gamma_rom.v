`timescale 1ns/1ns
// =============================================================================
//  gamma_rom -- 256x8 提升曲线 ROM（内容由 gamma_brt.hex 提供）
//  表值 = 255 * (x/255)^(1/1.8)，即把中间调抬亮的 gamma 曲线。
// =============================================================================
module gamma_rom (
    input  wire       clk,
    input  wire [7:0] addr,
    output reg  [7:0] q
);

    reg [7:0] mem [0:255];

    initial begin
        $readmemh("gamma_brt.hex", mem);
    end

    always @(posedge clk) begin
        q <= mem[addr];
    end

endmodule
