`timescale 1ns/1ns
// =============================================================================
//  hblur3 -- 每通道 3 抽头 [1 2 1]/4 水平平滑
//
//  作用：压掉 RAW->RGB 之后的高频颗粒噪点（AGC 放大前先降噪，
//        不然一加增益噪点跟着放大）。只做水平、只占 2 个寄存器/通道，
//        不动行缓存，时序代价很小。
//  延迟：输出固定比输入晚 2 拍，de/hs/vs 同步延迟。
// =============================================================================
module hblur3 (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       de,
    input  wire       hs,
    input  wire       vs,
    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,

    output reg  [7:0] o_r,
    output reg  [7:0] o_g,
    output reg  [7:0] o_b,
    output reg        o_de,
    output reg        o_hs,
    output reg        o_vs
);

    reg [7:0] r1, r2, g1, g2, b1, b2;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            r1 <= 8'd0; r2 <= 8'd0;
            g1 <= 8'd0; g2 <= 8'd0;
            b1 <= 8'd0; b2 <= 8'd0;
        end else begin
            r1 <= r;  r2 <= r1;
            g1 <= g;  g2 <= g1;
            b1 <= b;  b2 <= b1;
        end

    wire [9:0] sr = {2'd0, r2} + {1'd0, r1, 1'b0} + {2'd0, r};
    wire [9:0] sg = {2'd0, g2} + {1'd0, g1, 1'b0} + {2'd0, g};
    wire [9:0] sb = {2'd0, b2} + {1'd0, b1, 1'b0} + {2'd0, b};

    reg [1:0] de_d, hs_d, vs_d;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
            de_d <= 2'd0; hs_d <= 2'd0; vs_d <= 2'd0;
        end else begin
            o_r  <= sr[9:2];
            o_g  <= sg[9:2];
            o_b  <= sb[9:2];
            de_d <= {de_d[0], de};
            hs_d <= {hs_d[0], hs};
            vs_d <= {vs_d[0], vs};
        end

    always @(*) begin
        o_de = de_d[1];
        o_hs = hs_d[1];
        o_vs = vs_d[1];
    end

endmodule
