`timescale 1ns/1ns
// =============================================================================
//  img_rom -- 256x200 灰度图 ROM（$readmemh 从 img.hex 初始化）
//  用来在模组没修好之前，先把一张"红外风格"的图送到 HDMI 上，验证显示链路
// =============================================================================
module img_rom (
    input               clk,
    input       [15:0]  addr,      // {y[7:0], x[7:0]}
    output reg  [7:0]   q
);

    reg [7:0] mem [0:51199];

    initial begin
        $readmemh("img.hex", mem);
    end

    always @(posedge clk) begin
        q <= mem[addr];
    end

endmodule
