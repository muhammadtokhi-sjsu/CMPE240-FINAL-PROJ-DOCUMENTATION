`timescale 1ns / 1ps

module tpu_core_tb;

    localparam IN_W = 8;
    localparam ACC_W = 32;
    localparam N = 8;

    reg clk;
    reg rst;
    reg start;
    reg [N*N*IN_W-1:0] w_mat;
    reg [N*N*IN_W-1:0] x_mat;
    wire busy;
    wire done;
    wire [N*N*ACC_W-1:0] c_mat;

    integer errors, passes;
    integer i, j, k;

    reg signed [IN_W-1:0] X [0:N-1][0:N-1];
    reg signed [IN_W-1:0] W [0:N-1][0:N-1];
    reg signed [ACC_W-1:0] Cref [0:N-1][0:N-1];

    tpu_core #(
        .IN_W (IN_W),
        .ACC_W (ACC_W),
        .N (N)
    ) dut (
        .clk (clk),
        .rst (rst),
        .start (start),
        .w_mat (w_mat),
        .x_mat (x_mat),
        .busy (busy),
        .done (done),
        .c_mat (c_mat)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task build_and_pack;
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
                    x_mat[(i*N + j)*IN_W +: IN_W] = X[i][j];
                    w_mat[(i*N + j)*IN_W +: IN_W] = W[i][j];
                end
        end
    endtask

    task run_once;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            wait (done == 1'b1);
            @(negedge clk);
        end
    endtask

    task check_result;
        reg signed [ACC_W-1:0] got;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    got = c_mat[(i*N + j)*ACC_W +: ACC_W];
                    if (got !== Cref[i][j]) begin
                        errors = errors + 1;
                        $display("FAIL C[%0d][%0d]=%0d expected=%0d", i, j, got, Cref[i][j]);
                    end else begin
                        passes = passes + 1;
                        $display("PASS C[%0d][%0d]=%0d", i, j, got);
                    end
                end
        end
    endtask

    initial begin
        errors = 0;
        passes = 0;
        rst = 1'b1;
        start = 1'b0;
        w_mat = {N*N*IN_W{1'b0}};
        x_mat = {N*N*IN_W{1'b0}};

        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;

        build_and_pack(7);
        run_once;
        check_result;

        build_and_pack(3);
        run_once;
        check_result;

        if (errors == 0 && passes == 2*N*N)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED errors=%0d passes=%0d", errors, passes);

        $finish;
    end

endmodule
