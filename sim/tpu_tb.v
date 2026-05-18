`timescale 1ns / 1ps

module tpu_tb;

    localparam IN_W = 8;
    localparam ACC_W = 32;
    localparam N = 8;
    localparam ADDR_W = 12;

    localparam [11:0] CTRL_ADDR = 12'h000;
    localparam [11:0] STAT_ADDR = 12'h004;
    localparam [11:0] W_ADDR = 12'h040;
    localparam [11:0] X_ADDR = 12'h080;
    localparam [11:0] C_ADDR = 12'h100;

    localparam MAT_BITS = N*N*IN_W;

    reg clk;
    reg aresetn;

    reg [ADDR_W-1:0] awaddr;
    reg [2:0] awprot;
    reg awvalid;
    wire awready;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg wvalid;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready;
    reg [ADDR_W-1:0] araddr;
    reg [2:0] arprot;
    reg arvalid;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready;

    integer errors, passes;
    integer i, j, k;

    reg signed [IN_W-1:0] X [0:N-1][0:N-1];
    reg signed [IN_W-1:0] W [0:N-1][0:N-1];
    reg signed [ACC_W-1:0] Cref [0:N-1][0:N-1];
    reg [MAT_BITS-1:0] w_packed;
    reg [MAT_BITS-1:0] x_packed;
    reg [31:0] rd;

    tpu #(
        .IN_W (IN_W),
        .ACC_W (ACC_W),
        .N (N),
        .S_AXI_ADDR_WIDTH (ADDR_W)
    ) dut (
        .s_axi_aclk (clk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr (awaddr),
        .s_axi_awprot (awprot),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata (wdata),
        .s_axi_wstrb (wstrb),
        .s_axi_wvalid (wvalid),
        .s_axi_wready (wready),
        .s_axi_bresp (bresp),
        .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr),
        .s_axi_arprot (arprot),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata (rdata),
        .s_axi_rresp (rresp),
        .s_axi_rvalid (rvalid),
        .s_axi_rready (rready)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task axi_write;
        input [ADDR_W-1:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = addr;
            awvalid = 1'b1;
            wdata = data;
            wstrb = 4'b1111;
            wvalid = 1'b1;
            @(negedge clk);
            while (!(awready && wready))
                @(negedge clk);
            @(negedge clk);
            awvalid = 1'b0;
            wvalid = 1'b0;
            while (!bvalid)
                @(negedge clk);
        end
    endtask

    task axi_read;
        input [ADDR_W-1:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr = addr;
            arvalid = 1'b1;
            @(negedge clk);
            while (!arready)
                @(negedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid)
                @(negedge clk);
            data = rdata;
        end
    endtask

    task build;
        input integer seed;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    X[i][j] = i + j - seed;
                    W[i][j] = i - j + seed;
                end
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    Cref[i][j] = {ACC_W{1'b0}};
                    for (k = 0; k < N; k = k + 1)
                        Cref[i][j] = Cref[i][j] + X[i][k] * W[k][j];
                end
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    w_packed[(i*N + j)*IN_W +: IN_W] = W[i][j];
                    x_packed[(i*N + j)*IN_W +: IN_W] = X[i][j];
                end
        end
    endtask

    task do_matmul;
        input integer seed;
        begin
            build(seed);
            for (k = 0; k < 16; k = k + 1)
                axi_write(W_ADDR + k*4, w_packed[k*32 +: 32]);
            for (k = 0; k < 16; k = k + 1)
                axi_write(X_ADDR + k*4, x_packed[k*32 +: 32]);
            axi_write(CTRL_ADDR, 32'h0000_0001);
            rd = 32'd0;
            while (rd[0] !== 1'b1)
                axi_read(STAT_ADDR, rd);
            for (k = 0; k < 64; k = k + 1) begin
                axi_read(C_ADDR + k*4, rd);
                if (rd !== Cref[k/N][k%N]) begin
                    errors = errors + 1;
                    $display("FAIL C[%0d][%0d]=%0d expected=%0d", k/N, k%N, $signed(rd), Cref[k/N][k%N]);
                end else begin
                    passes = passes + 1;
                    $display("PASS C[%0d][%0d]=%0d", k/N, k%N, $signed(rd));
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        passes = 0;
        aresetn = 1'b0;
        awaddr = {ADDR_W{1'b0}};
        awprot = 3'b000;
        awvalid = 1'b0;
        wdata = 32'd0;
        wstrb = 4'b0000;
        wvalid = 1'b0;
        bready = 1'b1;
        araddr = {ADDR_W{1'b0}};
        arprot = 3'b000;
        arvalid = 1'b0;
        rready = 1'b1;

        repeat (4) @(negedge clk);
        aresetn = 1'b1;
        repeat (2) @(negedge clk);

        do_matmul(7);
        do_matmul(3);

        if (errors == 0 && passes == 2*N*N)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED errors=%0d passes=%0d", errors, passes);

        $finish;
    end

endmodule
