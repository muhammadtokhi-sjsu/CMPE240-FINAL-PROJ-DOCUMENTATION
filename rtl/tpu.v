module tpu #(
    parameter IN_W = 8,
    parameter ACC_W = 32,
    parameter N = 8,
    parameter S_AXI_ADDR_WIDTH = 12,
    parameter S_AXI_DATA_WIDTH = 32
) (
    input wire s_axi_aclk,
    input wire s_axi_aresetn,

    input wire [S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,

    input wire [S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input wire [(S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,

    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,

    input wire [S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,

    output wire [S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready
);

    localparam CTRL_IDX = 7'd0;
    localparam STAT_IDX = 7'd1;
    localparam W_BASE = 7'd16;
    localparam X_BASE = 7'd32;
    localparam C_BASE = 7'd64;

    localparam MAT_BITS = N*N*IN_W;
    localparam RES_BITS = N*N*ACC_W;
    localparam W_WORDS = MAT_BITS / 32;
    localparam X_WORDS = MAT_BITS / 32;
    localparam C_WORDS = RES_BITS / 32;

    wire clk = s_axi_aclk;
    wire rst = ~s_axi_aresetn;

    reg axi_awready;
    reg axi_wready;
    reg axi_bvalid;
    reg axi_arready;
    reg axi_rvalid;
    reg [S_AXI_DATA_WIDTH-1:0] axi_rdata;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready = axi_wready;
    assign s_axi_bvalid = axi_bvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_arready = axi_arready;
    assign s_axi_rvalid = axi_rvalid;
    assign s_axi_rdata = axi_rdata;
    assign s_axi_rresp = 2'b00;

    wire [6:0] wr_idx = s_axi_awaddr[8:2];
    wire [6:0] rd_idx = s_axi_araddr[8:2];

    wire write_hs = axi_awready & s_axi_awvalid & axi_wready & s_axi_wvalid;
    wire read_hs = axi_arready & s_axi_arvalid;

    reg [MAT_BITS-1:0] w_flat;
    reg [MAT_BITS-1:0] x_flat;
    wire [RES_BITS-1:0] c_flat;

    reg start_pulse;
    wire core_busy;
    wire core_done;

    always @(posedge clk) begin
        if (rst) begin
            axi_awready <= 1'b0;
            axi_wready <= 1'b0;
        end else if (!axi_awready && s_axi_awvalid && s_axi_wvalid && (!axi_bvalid || s_axi_bready)) begin
            axi_awready <= 1'b1;
            axi_wready <= 1'b1;
        end else begin
            axi_awready <= 1'b0;
            axi_wready <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst)
            axi_bvalid <= 1'b0;
        else if (write_hs)
            axi_bvalid <= 1'b1;
        else if (s_axi_bready)
            axi_bvalid <= 1'b0;
    end

    function [31:0] merge;
        input [31:0] old_w;
        input [31:0] new_w;
        input [3:0] strb;
        begin
            merge[7:0] = strb[0] ? new_w[7:0] : old_w[7:0];
            merge[15:8] = strb[1] ? new_w[15:8] : old_w[15:8];
            merge[23:16] = strb[2] ? new_w[23:16] : old_w[23:16];
            merge[31:24] = strb[3] ? new_w[31:24] : old_w[31:24];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            w_flat <= {MAT_BITS{1'b0}};
            x_flat <= {MAT_BITS{1'b0}};
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (write_hs) begin
                if (wr_idx == CTRL_IDX) begin
                    start_pulse <= s_axi_wdata[0];
                end else if (wr_idx >= W_BASE && wr_idx < W_BASE + W_WORDS) begin
                    w_flat[(wr_idx - W_BASE)*32 +: 32] <= merge(w_flat[(wr_idx - W_BASE)*32 +: 32], s_axi_wdata, s_axi_wstrb);
                end else if (wr_idx >= X_BASE && wr_idx < X_BASE + X_WORDS) begin
                    x_flat[(wr_idx - X_BASE)*32 +: 32] <= merge(x_flat[(wr_idx - X_BASE)*32 +: 32], s_axi_wdata, s_axi_wstrb);
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            axi_arready <= 1'b0;
        else if (!axi_arready && s_axi_arvalid && (!axi_rvalid || s_axi_rready))
            axi_arready <= 1'b1;
        else
            axi_arready <= 1'b0;
    end

    always @(posedge clk) begin
        if (rst)
            axi_rvalid <= 1'b0;
        else if (read_hs)
            axi_rvalid <= 1'b1;
        else if (s_axi_rready)
            axi_rvalid <= 1'b0;
    end

    reg [31:0] rd_data;
    always @(*) begin
        if (rd_idx == STAT_IDX)
            rd_data = {30'd0, core_busy, core_done};
        else if (rd_idx >= W_BASE && rd_idx < W_BASE + W_WORDS)
            rd_data = w_flat[(rd_idx - W_BASE)*32 +: 32];
        else if (rd_idx >= X_BASE && rd_idx < X_BASE + X_WORDS)
            rd_data = x_flat[(rd_idx - X_BASE)*32 +: 32];
        else if (rd_idx >= C_BASE && rd_idx < C_BASE + C_WORDS)
            rd_data = c_flat[(rd_idx - C_BASE)*32 +: 32];
        else
            rd_data = 32'd0;
    end

    always @(posedge clk) begin
        if (read_hs)
            axi_rdata <= rd_data;
    end

    tpu_core #(
        .IN_W (IN_W),
        .ACC_W (ACC_W),
        .N (N)
    ) u_core (
        .clk (clk),
        .rst (rst),
        .start (start_pulse),
        .w_mat (w_flat),
        .x_mat (x_flat),
        .busy (core_busy),
        .done (core_done),
        .c_mat (c_flat)
    );

endmodule
