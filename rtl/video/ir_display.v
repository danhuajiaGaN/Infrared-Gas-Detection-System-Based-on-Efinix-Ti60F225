`timescale 1ns/1ns
// =============================================================================
//  ir_display -- 红外图片通道：1080p60 时序 + 256x200 图 4x 放大居中 + ironbow 调色
//
//  为什么用 1080p60：摄像头通道走的就是 148.5 MHz / 1920x1080@60
//  （H: 44/148/1920/88 = 2200，V: 5/36/1080/4 = 1125，和 CEA-861 一致）。
//  两个通道用同一个像素时钟、同一套时序，切换时显示器不用重新协商。
//
//  图源 256x200，整数 4x 放大 -> 1024x800，正好和源图等比（1.28），居中：
//    左边 / 上边留黑 -> 窗口起点 (448, 140)
//
//  延迟：地址在 t1 给出 -> BMP 读 1 拍(t2) -> 调色板 1 拍(t3)，
//        hs/vs/de/win 同步延迟 3 拍，保证像素和消隐对齐。
// =============================================================================
module ir_display #(
    parameter H_SYNC  = 44,
    parameter H_BACK  = 148,
    parameter H_ACT   = 1920,
    parameter H_FRONT = 88,
    parameter V_SYNC  = 5,
    parameter V_BACK  = 36,
    parameter V_ACT   = 1080,
    parameter V_FRONT = 4,
    parameter WIN_X0  = 0,        // 活动区内偏移（0 = 占满整屏）
    parameter WIN_Y0  = 0,
    parameter WIN_W   = 1920,     // 满屏 1920
    parameter WIN_H   = 1080      // 满屏 1080
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         hs,
    output reg         vs,
    output reg         de,
    output reg  [23:0] rgb
);

    localparam H_TOTAL = H_SYNC + H_BACK + H_ACT + H_FRONT;   // 2200
    localparam V_TOTAL = V_SYNC + V_BACK + V_ACT + V_FRONT;   // 1125
    localparam H_AS    = H_SYNC + H_BACK;                     // 192 活动区起点
    localparam V_AS    = V_SYNC + V_BACK;                     // 41
    localparam WX_ABS  = H_AS + WIN_X0;                       // 640
    localparam WY_ABS  = V_AS + WIN_Y0;                       // 181

    //--------------------------------------------------------------------------
    // 时序计数器
    //--------------------------------------------------------------------------
    reg [11:0] hcnt;
    reg [10:0] vcnt;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            hcnt <= 12'd0;
            vcnt <= 11'd0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 11'd0 : vcnt + 11'd1;
        end else begin
            hcnt <= hcnt + 12'd1;
        end

    wire hs0 = (hcnt < H_SYNC);
    wire vs0 = (vcnt < V_SYNC);
    wire de0 = (hcnt >= H_AS) && (hcnt < H_AS + H_ACT) &&
               (vcnt >= V_AS) && (vcnt < V_AS + V_ACT);

    // 窗口内相对坐标（无符号相减，窗口外会回绕成很大的数，比较自然为假）
    wire [11:0] wx0 = hcnt - WX_ABS;
    wire [11:0] wy0 = vcnt - WY_ABS;
    wire        win0 = de0 && (wx0 < WIN_W) && (wy0 < WIN_H);

    //--------------------------------------------------------------------------
    // 第一级：坐标/同步寄存器
    //--------------------------------------------------------------------------
    reg [11:0] wx1, wy1;
    reg        de1, hs1, vs1, win1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            wx1 <= 12'd0; wy1 <= 12'd0;
            de1 <= 1'b0;  hs1 <= 1'b0;  vs1 <= 1'b0;  win1 <= 1'b0;
        end else begin
            wx1  <= wx0;
            wy1  <= wy0;
            de1  <= de0;
            hs1  <= hs0;
            vs1  <= vs0;
            win1 <= win0;
        end

    //--------------------------------------------------------------------------
    // 无规律抖动：每帧用 16bit LFSR 生成新的整幅图偏移（X: -4..+3，Y: -3..+4 源像素），
    // 方向幅度都随机，整幅图连同图中的框一起抖；只在帧边界更新，不会撕裂。
    //--------------------------------------------------------------------------
    reg         vs0_d;
    reg  [15:0] lfsr;
    reg  signed [3:0] jit_x, jit_y;
    reg  [2:0]  jit_div;          // 每 8 帧才换一次偏移 → 慢慢漂，不会一直在抖

    wire vs_rise0 = vs0 & ~vs0_d;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            vs0_d   <= 1'b0;
            lfsr    <= 16'hACE1;
            jit_x   <= 4'sd0;
            jit_y   <= 4'sd0;
            jit_div <= 3'd0;
        end else begin
            vs0_d <= vs0;
            if (vs_rise0) begin
                // x^16 + x^14 + x^13 + x^11 + 1 伪随机序列
                lfsr    <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
                jit_div <= jit_div + 3'd1;
                // 整幅图不平移（用户不要这个效果），只保留像素级微噪
                jit_x   <= 4'sd0;
                jit_y   <= 4'sd0;
            end
        end

    //--------------------------------------------------------------------------
    // 全屏映射：1920x1080 -> 256x200（非整数缩放，最近邻）
    //   sx = wx * 256/1920  = wx * 2185 >> 14
    //   sy = (1079-wy) * 200/1080 = (1079-wy) * 3034 >> 14   ← 同时做上下翻转
    //   地址 = {y[7:0], x[7:0]}
    //--------------------------------------------------------------------------
    wire [11:0] flip_y = 12'd1079 - wy1;
    wire [21:0] mul_x  = wx1  * 16'd2185;
    wire [21:0] mul_y  = flip_y * 16'd3034;

    // 抖动偏移（jit_x/jit_y 已经是 -4..+3 的有符号数），带钳位
    wire signed [4:0] ox = jit_x;
    wire signed [4:0] oy = jit_y;

    wire signed [10:0] sx_s = $signed({3'b000, mul_x[21:14]}) + {{6{ox[4]}}, ox};
    wire signed [10:0] sy_s = $signed({3'b000, mul_y[21:14]}) + {{6{oy[4]}}, oy};

    wire [7:0] sx = (sx_s < 0)      ? 8'd0   :
                    (sx_s > 11'sd255) ? 8'd255 : sx_s[7:0];
    wire [7:0] sy = (sy_s < 0)      ? 8'd0   :
                    (sy_s > 11'sd255) ? 8'd255 : sy_s[7:0];

    wire [15:0] rom_addr = {sy, sx};
    wire [7:0]  gray;

    img_rom u_img (
        .clk  (clk),
        .addr (rom_addr),
        .q    (gray)
    );

    wire [23:0] pal_rgb;

    //--------------------------------------------------------------------------
    // 像素级抖动：已关闭（用户不要任何闪动），画面完全静止
    //   想重新开启：把 gd 改成下注里被注释的那一行即可
    //--------------------------------------------------------------------------
    // reg [15:0] pn;
    // always @(posedge clk or negedge rst_n)
    //     if (!rst_n) pn <= 16'h1234;
    //     else        pn <= {pn[14:0], pn[15] ^ pn[13] ^ pn[12] ^ pn[10]};
    // wire signed [5:0]  nz   = pn[5] ? 6'sd1 : (pn[6] ? -6'sd1 : 6'sd0);
    // wire signed [10:0] gsum = $signed({3'b000, gray}) + {{5{nz[5]}}, nz};
    // wire [7:0] gd = (gsum < 0) ? 8'd0 : (gsum > 11'sd255) ? 8'd255 : gsum[7:0];

    wire [7:0] gd = gray;

    // 8bit 灰度直通（图本身是夜景灰度图，直通保留细节最清楚）
    // 想换回 ironbow 伪彩：把这两行换成 palette_rom 实例即可
    reg [23:0] pal_rgb_r;
    always @(posedge clk) begin
        pal_rgb_r <= {gd, gd, gd};
    end
    assign pal_rgb = pal_rgb_r;

    //--------------------------------------------------------------------------
    // 同步信号再延 2 拍（和 ROM + 调色板对齐）
    //--------------------------------------------------------------------------
    reg de2, de3, hs2, hs3, vs2, vs3, win2, win3;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            de2 <= 1'b0; hs2 <= 1'b0; vs2 <= 1'b0; win2 <= 1'b0;
            de3 <= 1'b0; hs3 <= 1'b0; vs3 <= 1'b0; win3 <= 1'b0;
        end else begin
            de2  <= de1;  hs2  <= hs1;  vs2  <= vs1;  win2  <= win1;
            de3  <= de2;  hs3  <= hs2;  vs3  <= vs2;  win3  <= win2;
        end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            hs  <= 1'b0;
            vs  <= 1'b0;
            de  <= 1'b0;
            rgb <= 24'h000000;
        end else begin
            hs  <= hs3;
            vs  <= vs3;
            de  <= de3;
            rgb <= win3 ? pal_rgb : 24'h000000;   // 窗口外黑边
        end

endmodule
