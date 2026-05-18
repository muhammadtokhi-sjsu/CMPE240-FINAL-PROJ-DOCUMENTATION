`timescale 1ns / 1ps

module pe_array_tb;

    localparam IN_W = 8;
    localparam ACC_W = 32;
    localparam N = 8;

    reg clk;
    reg rst;
    reg w_load;
    reg signed [N*IN_W-1:0] w_in;
    reg signed [N*IN_W-1:0] act_in;
    wire signed [N*ACC_W-1:0] psum_out;

    integer errors;
    integer passes;
    integer n, i, j, k, idx;

    reg signed [IN_W-1:0] X [0:N-1][0:N-1];
    reg signed [IN_W-1:0] W [0:N-1][0:N-1];
    reg signed [ACC_W-1:0] Cref [0:N-1][0:N-1];

    pe_array #(
        .IN_W (IN_W),
        .ACC_W (ACC_W),
        .N (N)
    ) dut (
        .clk (clk),
        .rst (rst),
        .w_load (w_load),
        .w_in (w_in),
        .act_in (act_in),
        .psum_out (psum_out)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task drive_load;
        input integer cyc;
        begin
            w_load = 1'b1;
            for (j = 0; j < N; j = j + 1) begin
                w_in[j*IN_W +: IN_W] = W[N-1-cyc][j];
                act_in[j*IN_W +: IN_W] = {IN_W{1'b0}};
            end
        end
    endtask

    task drive_stream;
        input integer cyc;
        begin
            w_load = 1'b0;
            for (j = 0; j < N; j = j + 1) begin
                w_in[j*IN_W +: IN_W] = {IN_W{1'b0}};
                idx = (cyc - N) - j;
                if (idx >= 0 && idx < N)
                    act_in[j*IN_W +: IN_W] = X[idx][j];
                else
                    act_in[j*IN_W +: IN_W] = {IN_W{1'b0}};
            end
        end
    endtask

    task sample_check;
        input integer p;
        integer m, cc;
        reg signed [ACC_W-1:0] got;
        begin
            for (cc = 0; cc < N; cc = cc + 1) begin
                m = p - (2*N - 1) - cc;
                if (m >= 0 && m < N) begin
                    got = psum_out[cc*ACC_W +: ACC_W];
                    if (got !== Cref[m][cc]) begin
                        errors = errors + 1;
                        $display("FAIL C[%0d][%0d]=%0d expected=%0d", m, cc, got, Cref[m][cc]);
                    end else begin
                        passes = passes + 1;
                        $display("PASS C[%0d][%0d]=%0d", m, cc, got);
                    end
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        passes = 0;
        rst = 1'b1;
        w_load = 1'b0;
        w_in = {N*IN_W{1'b0}};
        act_in = {N*IN_W{1'b0}};

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                X[i][j] = i + j - 7;
                W[i][j] = i - j;
            end

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                Cref[i][j] = {ACC_W{1'b0}};
                for (k = 0; k < N; k = k + 1)
                    Cref[i][j] = Cref[i][j] + X[i][k] * W[k][j];
            end

        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (n = 0; n < 4*N + 4; n = n + 1) begin
            @(negedge clk);
            if (n >= 1)
                sample_check(n - 1);
            if (n < N)
                drive_load(n);
            else
                drive_stream(n);
        end

        @(negedge clk);
        sample_check(4*N + 3);

        if (errors == 0 && passes == N*N)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED errors=%0d passes=%0d", errors, passes);

        $finish;
    end

endmodule
