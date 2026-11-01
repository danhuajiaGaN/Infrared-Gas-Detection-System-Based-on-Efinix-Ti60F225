`timescale 1ns/1ns
// =============================================================================
//  key_mode -- 一键切换：消抖 + 三态循环 + LED 指示
//
//  mode: 0 = 摄像头 + 自适应增强（默认，开机就是这个）
//        1 = 摄像头原图（绕过增强，用来对比"暗不暗"）
//        2 = 红外图片（tn256 那套 256x200 图 + ironbow 调色板）
//  每按一次循环 0 -> 1 -> 2 -> 0。
//
//  两颗键都行（板子《按键管脚分配》）：
//     key_n  = KEY3  GPIOL_03 / A3  / Bank TL
//     key_n2 = KEY0  GPIOL_07 / C4  / Bank TL
//  按下为低电平（按键对地）；内部不用上拉，靠板载上拉。
//
//  消抖：各打 3 拍同步，再每 20 ms 采样一次（148.5 MHz 下 2_970_000 拍），
//        采到下降沿算一次按下 —— 机械抖动和手抖都不会多跳。
// =============================================================================
module key_mode (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_n,        // KEY3，低有效
    input  wire        key_n2,       // KEY0，低有效（备用，按哪颗都能切）

    output reg  [1:0]  mode,
    output wire [2:0]  mode_led      // {红外, 原图, 增强}
);

    localparam [21:0] DIV_MAX = 22'd2_970_000;   // 20 ms @ 148.5 MHz

    //--------------------------------------------------------------------------
    // 两个异步输入 -> 各打 3 拍同步
    //--------------------------------------------------------------------------
    reg k1_a, k2_a, k3_a;
    reg k1_b, k2_b, k3_b;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            k1_a <= 1'b1; k2_a <= 1'b1; k3_a <= 1'b1;
            k1_b <= 1'b1; k2_b <= 1'b1; k3_b <= 1'b1;
        end else begin
            k1_a <= key_n;   k2_a <= k1_a;   k3_a <= k2_a;
            k1_b <= key_n2;  k2_b <= k1_b;   k3_b <= k2_b;
        end

    //--------------------------------------------------------------------------
    // 20 ms 采样 + 下降沿检测（两颗键任意一颗按下都算一次）
    //--------------------------------------------------------------------------
    reg [21:0] div;
    reg        key_s,  key_sd;
    reg        key_s2, key_sd2;

    wire press_a = key_sd  & ~key_s;
    wire press_b = key_sd2 & ~key_s2;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            div    <= 22'd0;
            key_s  <= 1'b1;
            key_sd <= 1'b1;
            key_s2 <= 1'b1;
            key_sd2<= 1'b1;
            mode   <= 2'd0;
        end else if (div == DIV_MAX - 1) begin
            div    <= 22'd0;
            key_s  <= k3_a;
            key_sd <= key_s;
            key_s2 <= k3_b;
            key_sd2<= key_s2;
            if (press_a || press_b)                  // 按下一次
                mode <= (mode == 2'd2) ? 2'd0 : mode + 2'd1;
        end else begin
            div <= div + 22'd1;
        end

    assign mode_led = (mode == 2'd0) ? 3'b001 :
                      (mode == 2'd1) ? 3'b010 : 3'b100;

endmodule

// =============================================================================
//  下面两个模块（sobel_3x3 / line_ram）本来各占一个文件，现在并到本文件里：
//  Efinity 跑 map/interface 时会重写工程 XML 的 design_file 表，把'工程建好之后
//  才加进去的源文件'悄悄删掉（实测 66 条 -> 64 条），导致下次 map 报
//  instantiating unknown module 'sobel_3x3'。放进已登记的 key_mode.v 就不会再丢。
// =============================================================================

`timescale 1ns/1ns
// =============================================================================
//  sobel_3x3 -- 3x3 Sobel 边缘检测（8bit 灰度输出，白边黑底）
//
//  结构：
//    RGB -> BT.601 亮度 y (77R+150G+29B)>>8
//    两行行缓存（各 1920x8 BSRAM，逐行交替读写）拿到上一行 / 上上行
//    三路各打 2 拍 -> 3x3 九抽头窗口
//    Gx = (左上 + 2*上 + 右上) - (左下 + 2*下 + 右下)
//    Gy = (左上 + 2*左 + 左下) - (右上 + 2*右 + 右下)
//    mag = |Gx| + |Gy| - THRESH（低于 THRESH 归 0，压掉暗环境放大的噪点），饱和到 255
//
//  延迟固定 4 个像素时钟，de/hs/vs 同步延迟。
//  行缓存按 de 计数寻址；消隐期不写，读到的旧值反正会被 de 屏蔽。
// =============================================================================
module sobel_3x3 #(
    parameter WIDTH  = 1920,     // 行宽（像素），行缓存深度
    parameter THRESH = 16,       // 死区：梯度低于它就归 0（压暗环境放大的噪点）
    parameter GAIN   = 1         // 梯度放大 2^GAIN 倍：1 = 2x（默认），2 = 4x，0 = 1x
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,

    output reg  [7:0]  o_y,
    output wire        o_de,
    output wire        o_hs,
    output wire        o_vs
);

    //--------------------------------------------------------------------------
    // 1) 亮度
    //--------------------------------------------------------------------------
    wire [15:0] ysum = (16'd77 * r) + (16'd150 * g) + (16'd29 * b);
    wire [7:0]  y    = ysum[15:8];

    //--------------------------------------------------------------------------
    // 2) 行内计数 + 行号（3 取模）
    //--------------------------------------------------------------------------
    reg [10:0] x_cnt;
    reg [1:0]  rp;           // 行指针：0,1,2 循环，决定这块行缓存"写"
    reg        de_d0;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            x_cnt <= 11'd0;
            rp    <= 2'd0;
            de_d0 <= 1'b0;
        end else begin
            de_d0 <= de;
            if (!de) x_cnt <= 11'd0;
            else     x_cnt <= x_cnt + 11'd1;
            // 行尾推进一行（消隐期完成，不影响本行）
            if (de_d0 & ~de)
                rp <= (rp == 2'd2) ? 2'd0 : rp + 2'd1;
        end

    //--------------------------------------------------------------------------
    // 3) 三块行缓存环形轮转
    //
    //    为什么不用"两块 + 一写一读"：那样会出现"同一拍、同一地址又写又读"
    //    （写本行、读两行前），能不能读出旧值取决于工具把 BRAM 推断成
    //    read-first 还是 write-first；推断错就变成 top == bot，
    //    竖直梯度恒为 0，边缘会时有时无。
    //    三块轮转后：写的那块永不读，读的两块永不被写 —— 彻底没这问题。
    //
    //    ram[rp] 正在写本行；ram[rp+1] 是两行前；ram[rp+2] 是一行前
    //--------------------------------------------------------------------------
    wire we0 = de & (rp == 2'd0);
    wire we1 = de & (rp == 2'd1);
    wire we2 = de & (rp == 2'd2);

    wire [7:0] q0, q1, q2;

    line_ram #(.WIDTH(WIDTH)) u_ram0 (
        .clk(clk), .we(we0), .addr(x_cnt[10:0]), .din(y), .q(q0)
    );
    line_ram #(.WIDTH(WIDTH)) u_ram1 (
        .clk(clk), .we(we1), .addr(x_cnt[10:0]), .din(y), .q(q1)
    );
    line_ram #(.WIDTH(WIDTH)) u_ram2 (
        .clk(clk), .we(we2), .addr(x_cnt[10:0]), .din(y), .q(q2)
    );

    // 上一行 = (rp+2)%3，上上行 = (rp+1)%3
    wire [7:0] q_prev  = (rp == 2'd0) ? q2 : (rp == 2'd1) ? q0 : q1;
    wire [7:0] q_prev2 = (rp == 2'd0) ? q1 : (rp == 2'd1) ? q2 : q0;

    //--------------------------------------------------------------------------
    // 4) 对齐与九抽头
    //
    //    ⚠ 关键：行缓存输出 qa/qb 自带一拍延迟（这一拍给地址、下一拍出数据），
    //    所以"本行"的亮度也必须多打一拍（yq），三行才是同一列；
    //    少打这一拍，3x3 窗口就是斜的（错开一列），边缘会变成重影 + 斜纹。
    //
    //    par=0：本行写 A -> A 里是"上上行"，B 里是"上一行"
    //    par=1：本行写 B -> B 里是"上上行"，A 里是"上一行"
    //--------------------------------------------------------------------------
    reg  [7:0] yq;
    always @(posedge clk) yq <= y;

    wire [7:0] bot_n = yq;                      // 本行，  列 c
    wire [7:0] mid_n = q_prev;                  // 上一行，列 c
    wire [7:0] top_n = q_prev2;                 // 上上行，列 c

    reg [7:0] bot_1, mid_1, top_1;              // 列 c-1
    reg [7:0] bot_2, mid_2, top_2;              // 列 c-2

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            bot_1 <= 8'd0;  mid_1 <= 8'd0;  top_1 <= 8'd0;
            bot_2 <= 8'd0;  mid_2 <= 8'd0;  top_2 <= 8'd0;
        end else begin
            bot_1 <= bot_n;  mid_1 <= mid_n;  top_1 <= top_n;
            bot_2 <= bot_1;  mid_2 <= mid_1;  top_2 <= top_1;
        end

    //--------------------------------------------------------------------------
    // 5) 梯度（全程无符号，先比大小再相减 = 直接取绝对值）
    //--------------------------------------------------------------------------
    wire [10:0] s_top = {3'd0, top_2} + {2'd0, top_1, 1'b0} + {3'd0, top_n};
    wire [10:0] s_bot = {3'd0, bot_2} + {2'd0, bot_1, 1'b0} + {3'd0, bot_n};
    wire [10:0] s_lft = {3'd0, top_2} + {2'd0, mid_2, 1'b0} + {3'd0, bot_2};
    wire [10:0] s_rgt = {3'd0, top_n} + {2'd0, mid_n, 1'b0} + {3'd0, bot_n};

    wire [10:0] gx = (s_top > s_bot) ? (s_top - s_bot) : (s_bot - s_top);
    wire [10:0] gy = (s_lft > s_rgt) ? (s_lft - s_rgt) : (s_rgt - s_lft);
    // 取 max(|Gx|,|Gy|) 而不是相加：边缘更细更锐，不会被斜向叠加糊成一片
    wire [10:0] gmax    = (gx > gy) ? gx : gy;
    wire [11:0] mag_sum = {1'b0, gmax};
    wire [11:0] mag_z   = (mag_sum > THRESH) ? (mag_sum - THRESH) : 12'd0;
    wire [11:0] mag     = mag_z << GAIN;      // 放大后再饱和，边缘才够亮

    // 说明：|Gx|+|Gy| 对一个幅度 A 的台阶边，最大约 4A。
    // A=20 的小边缘：mag_sum=80 -> 减 16 -> 64 -> 2x -> 128（亮灰）
    // A=40 的强边缘：160 -> 144 -> 288 -> 饱和 255（纯白）
    // A=4 的噪点：16 -> 0（被死区吃掉）

    //--------------------------------------------------------------------------
    // 6) 输出（亮度通道，三色相同 = 白边黑底）
    //    窗口在 cycle2 齐、mag 组合算、o_y 在 cycle3 有效
    //    -> 同步信号取 de_d[2]（延迟 3 拍），不能再多打一拍
    //--------------------------------------------------------------------------
    reg [3:0] de_d, hs_d, vs_d;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            o_y  <= 8'd0;
            de_d <= 4'd0;
            hs_d <= 4'd0;
            vs_d <= 4'd0;
        end else begin
            o_y  <= (mag > 12'd255) ? 8'hFF : mag[7:0];
            de_d <= {de_d[2:0], de};
            hs_d <= {hs_d[2:0], hs};
            vs_d <= {vs_d[2:0], vs};
        end

    assign o_de = de_d[2];
    assign o_hs = hs_d[2];
    assign o_vs = vs_d[2];

endmodule

`timescale 1ns/1ns
// =============================================================================
//  line_ram -- Sobel 用的行缓存（单写口 + 单读口，读优先/read-first）
//
//  写和读用同一个地址：这一拍写进去的是"本行"，读出来的是这块 RAM 里
//  上一次写进去的内容（也就是两行前），所以不会打架。
//  Efinity 会推成 BSRAM（1920x8 = 大约 2 块）。
// =============================================================================
module line_ram #(
    parameter WIDTH = 1920
)(
    input  wire        clk,
    input  wire        we,
    input  wire [10:0] addr,
    input  wire [7:0]  din,
    output reg  [7:0]  q
);

    reg [7:0] mem [0:WIDTH-1];

    always @(posedge clk) begin
        if (we) mem[addr] <= din;
        q <= mem[addr];
    end

endmodule
