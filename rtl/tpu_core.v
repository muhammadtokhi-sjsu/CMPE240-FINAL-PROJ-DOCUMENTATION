module tpu_core #(
    parameter IN_W = 8,
    parameter ACC_W = 32,
    parameter N = 8
) (
    input wire clk,
    input wire rst,
    input wire start,
    input wire [N*N*IN_W-1:0] w_mat,
    input wire [N*N*IN_W-1:0] x_mat,
    output wire busy,
    output wire done,
    output reg [N*N*ACC_W-1:0] c_mat
);

    localparam S_IDLE = 2'd0;
    localparam S_RUN = 2'd1;
    localparam S_DONE = 2'd2;

    localparam LOAD_LAST = N - 1;
    localparam STREAM_FIRST = N;
    localparam STREAM_LAST = 2*N - 1;
    localparam CAP_FIRST = 3*N - 1;
    localparam CAP_LAST = 4*N - 2;
    localparam RUN_LAST = 4*N - 2;

    reg [1:0] state;
    reg [7:0] cnt;

    wire w_load;
    wire streaming;
    wire capturing;

    wire [31:0] wrow;
    wire [31:0] xrow;
    wire [31:0] caprow;

    wire [N*IN_W-1:0] arr_w_in;
    wire [N*IN_W-1:0] skew_in_din;
    wire [N*IN_W-1:0] arr_act_in;
    wire [N*ACC_W-1:0] arr_psum_out;
    wire [N*ACC_W-1:0] skew_out_dout;

    assign busy = (state == S_RUN);
    assign done = (state == S_DONE);

    assign w_load = (state == S_RUN) && (cnt <= LOAD_LAST);
    assign streaming = (state == S_RUN) && (cnt >= STREAM_FIRST) && (cnt <= STREAM_LAST);
    assign capturing = (state == S_RUN) && (cnt >= CAP_FIRST) && (cnt <= CAP_LAST);

    assign wrow = (cnt <= LOAD_LAST) ? (LOAD_LAST - cnt) : 32'd0;
    assign xrow = streaming ? (cnt - STREAM_FIRST) : 32'd0;
    assign caprow = capturing ? (cnt - CAP_FIRST) : 32'd0;

    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_feed
            assign arr_w_in[gi*IN_W +: IN_W] = w_mat[(wrow*N + gi)*IN_W +: IN_W];
            assign skew_in_din[gi*IN_W +: IN_W] = streaming ? x_mat[(xrow*N + gi)*IN_W +: IN_W] : {IN_W{1'b0}};
        end
    endgenerate

    skew #(
        .WIDTH (IN_W),
        .N (N),
        .DIR (0)
    ) u_skew_in (
        .clk (clk),
        .rst (rst),
        .d_in (skew_in_din),
        .d_out (arr_act_in)
    );

    pe_array #(
        .IN_W (IN_W),
        .ACC_W (ACC_W),
        .N (N)
    ) u_array (
        .clk (clk),
        .rst (rst),
        .w_load (w_load),
        .w_in (arr_w_in),
        .act_in (arr_act_in),
        .psum_out (arr_psum_out)
    );

    skew #(
        .WIDTH (ACC_W),
        .N (N),
        .DIR (1)
    ) u_skew_out (
        .clk (clk),
        .rst (rst),
        .d_in (arr_psum_out),
        .d_out (skew_out_dout)
    );

    integer c;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            cnt <= 8'd0;
            c_mat <= {N*N*ACC_W{1'b0}};
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_RUN;
                        cnt <= 8'd0;
                    end
                end
                S_RUN: begin
                    if (capturing) begin
                        for (c = 0; c < N; c = c + 1)
                            c_mat[(caprow*N + c)*ACC_W +: ACC_W] <= skew_out_dout[c*ACC_W +: ACC_W];
                    end
                    if (cnt == RUN_LAST)
                        state <= S_DONE;
                    else
                        cnt <= cnt + 8'd1;
                end
                S_DONE: begin
                    if (start) begin
                        state <= S_RUN;
                        cnt <= 8'd0;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
