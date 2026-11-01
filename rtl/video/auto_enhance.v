`timescale 1ns/1ns
// =============================================================================
//  auto_enhance -- 自适应亮度增强（AGC + 提升曲线）
//
//  为什么需要它：
//    摄像头（SC431HAI）出来的 8bit RGB 在室内/傍晚就是偏暗；原来工程里还挂了一张
//    gamma=2.2 的 "校正" 表（2P2.mem），那是把中间调往下压的曲线
//    （输入 128 -> 输出约 55），画面更暗。
//
//  这个模块做两件事：
//    1) 测光（AGC）：每帧统计有效像素的平均亮度 mean，闭环调节数字增益 gain，
//       把 mean 拉进 [TGT_LO, TGT_HI] 窗口。每帧最多动 2（Q4.4，1/8 倍），
//       60fps 下约 0.3 s 收敛，不会忽明忽暗。
//    2) 提亮：增益之后的每个通道查一张 gamma=1/1.8 的提升表，把中间调抬起来，
//       高光不会糊（表里 255 还是 255）。
//
//  延迟：固定 3 个像素时钟，de/hs/vs 同步延迟，时序对齐由模块内部保证。
//  只用 1 个乘法器算亮度（77/150/29 是 BT.601 系数）+ 3 个 8x6 增益乘法。
// =============================================================================
module auto_enhance (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,

    output wire [7:0]  o_r,
    output wire [7:0]  o_g,
    output wire [7:0]  o_b,
    output wire        o_de,
    output wire        o_hs,
    output wire        o_vs,

    output reg  [7:0]  o_mean,      // 上一帧平均亮度（调试 / LED 用）
    output reg  [5:0]  o_gain       // 当前增益 Q4.4（16 = 1.0x）
);

    //--------------------------------------------------------------------------
    // 目标与限制
    //--------------------------------------------------------------------------
    localparam [7:0] TGT_LO = 8'd62;    // 太暗：加增益（后面还有 1/1.8 提升，留余量）
    localparam [7:0] TGT_HI = 8'd78;    // 太亮：减增益
    localparam [5:0] G_MIN  = 6'd8;     // 0.50x（白天太亮可以压下来）
    localparam [5:0] G_MAX  = 6'd40;    // 2.50x（再高就把噪点一起放大）

    //--------------------------------------------------------------------------
    // 1) 亮度统计
    //    y = (77R + 150G + 29B) >> 8
    //    每 4 个像素取 1 个 -> 一行 480 个样本；行内先累加成 row_sum，
    //    行尾再并入 frame_sum，避免 32bit 加法器跑在像素时钟上。
    //--------------------------------------------------------------------------
    wire [15:0] y_sum = (16'd77 * r) + (16'd150 * g) + (16'd29 * b);

    reg  [15:0] y_r;
    always @(posedge clk) y_r <= y_sum[15:8];

    reg  [10:0] x_cnt;
    reg         de_d0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            x_cnt <= 11'd0;
            de_d0 <= 1'b0;
        end else begin
            de_d0 <= de;
            if (!de) x_cnt <= 11'd0;
            else     x_cnt <= x_cnt + 11'd1;
        end

    wire sample = de & (x_cnt[1:0] == 2'b00);

    reg  [19:0] row_sum;
    reg  [31:0] frame_sum;
    wire row_end = de_d0 & ~de;          // de 下降沿 = 一行结束

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            row_sum   <= 20'd0;
            frame_sum <= 32'd0;
        end else if (row_end) begin
            row_sum   <= 20'd0;
            frame_sum <= frame_sum + {12'd0, row_sum};
        end else if (sample) begin
            row_sum   <= row_sum + {12'd0, y_r[15:8]};
        end

    // 一帧样本数 = 每行样本数 x 1080。每行样本数随像素时钟/有效宽度而变
    // （1920 有效 -> 480 个/行；若只 960 有效 -> 240 个/行），
    // 这里按行样本数选移位量代替除法：>=360 用 /2^19，否则 /2^18。
    reg [11:0] n_line, n_line_l;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            n_line   <= 12'd0;
            n_line_l <= 12'd480;
        end else if (row_end) begin
            n_line   <= 12'd0;
            n_line_l <= n_line;
        end else if (sample) begin
            n_line   <= n_line + 12'd1;
        end

    wire        sh19   = (n_line_l >= 12'd360);
    wire [8:0]  mean_a = sh19 ? frame_sum[27:19] : frame_sum[26:18];
    wire [7:0]  mean8  = (mean_a > 9'd255) ? 8'hFF : mean_a[7:0];

    reg        vs_d;
    always @(posedge clk) vs_d <= vs;
    wire frame_end = vs & ~vs_d;         // vs 上升沿 = 新的一帧

    //--------------------------------------------------------------------------
    // 2) 增益闭环（每帧最多 +/- 2，带死区）
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            o_gain <= G_MIN;
            o_mean <= 8'd0;
        end else if (frame_end) begin
            o_mean <= mean8;
            if (mean8 < TGT_LO)
                o_gain <= (o_gain > G_MAX - 6'd2) ? G_MAX : o_gain + 6'd2;
            else if (mean8 > TGT_HI)
                o_gain <= (o_gain < G_MIN + 6'd2) ? G_MIN : o_gain - 6'd2;
        end

    //--------------------------------------------------------------------------
    // 3) 增益 + 饱和（两级流水）
    //--------------------------------------------------------------------------
    reg [13:0] prod_r, prod_g, prod_b;
    reg [7:0]  g_r, g_g, g_b;

    wire [9:0] shr = prod_r[13:4];
    wire [9:0] shg = prod_g[13:4];
    wire [9:0] shb = prod_b[13:4];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            prod_r <= 14'd0; prod_g <= 14'd0; prod_b <= 14'd0;
            g_r    <= 8'd0;  g_g    <= 8'd0;  g_b    <= 8'd0;
        end else begin
            prod_r <= r * o_gain;
            prod_g <= g * o_gain;
            prod_b <= b * o_gain;

            g_r <= (shr > 10'd255) ? 8'hFF : shr[7:0];
            g_g <= (shg > 10'd255) ? 8'hFF : shg[7:0];
            g_b <= (shb > 10'd255) ? 8'hFF : shb[7:0];
        end

    //--------------------------------------------------------------------------
    // 4) gamma 1/1.8 提升表（每通道一张 256x8 ROM）
    //--------------------------------------------------------------------------
    gamma_rom u_gr (.clk(clk), .addr(g_r), .q(o_r));
    gamma_rom u_gg (.clk(clk), .addr(g_g), .q(o_g));
    gamma_rom u_gb (.clk(clk), .addr(g_b), .q(o_b));

    //--------------------------------------------------------------------------
    // 5) 同步信号延迟 3 拍
    //--------------------------------------------------------------------------
    reg [2:0] de_d, hs_d, vs_d2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            de_d  <= 3'd0;
            hs_d  <= 3'd0;
            vs_d2 <= 3'd0;
        end else begin
            de_d  <= {de_d[1:0],  de};
            hs_d  <= {hs_d[1:0],  hs};
            vs_d2 <= {vs_d2[1:0], vs};
        end

    assign o_de = de_d[2];
    assign o_hs = hs_d[2];
    assign o_vs = vs_d2[2];

endmodule
