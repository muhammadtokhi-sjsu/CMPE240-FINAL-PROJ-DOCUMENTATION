`timescale 1ns / 1ps

module skew_tb;

    localparam WIDTH = 8;
    localparam N = 8;
    localparam NCYC = 20;

    reg clk;
    reg rst;
    reg [N*WIDTH-1:0] d_in;
    wire [N*WIDTH-1:0] d_out_asc;
    wire [N*WIDTH-1:0] d_out_desc;

    integer errors;
    integer passes;
    integer t, i;

    skew #(.WIDTH(WIDTH), .N(N), .DIR(0)) dut_asc (
        .clk (clk),
        .rst (rst),
        .d_in (d_in),
        .d_out (d_out_asc)
    );

    skew #(.WIDTH(WIDTH), .N(N), .DIR(1)) dut_desc (
        .clk (clk),
        .rst (rst),
        .d_in (d_in),
        .d_out (d_out_desc)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function [WIDTH-1:0] gen;
        input integer lane;
        input integer cyc;
        begin
            gen = lane*16 + cyc + 1;
        end
    endfunction

    task check_lane;
        input integer lane;
        input integer cyc;
        input integer delay;
        input [WIDTH-1:0] got;
        reg [WIDTH-1:0] exp;
        begin
            if (cyc >= delay)
                exp = gen(lane, cyc - delay);
            else
                exp = {WIDTH{1'b0}};
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL t=%0d lane=%0d got=%0d expected=%0d", cyc, lane, got, exp);
            end else begin
                passes = passes + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        passes = 0;
        rst = 1'b1;
        d_in = {N*WIDTH{1'b0}};

        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (t = 0; t < NCYC; t = t + 1) begin
            @(negedge clk);
            for (i = 0; i < N; i = i + 1)
                d_in[i*WIDTH +: WIDTH] = gen(i, t);
            #1;
            for (i = 0; i < N; i = i + 1) begin
                check_lane(i, t, i, d_out_asc[i*WIDTH +: WIDTH]);
                check_lane(i, t, N-1-i, d_out_desc[i*WIDTH +: WIDTH]);
            end
        end

        if (errors == 0 && passes == 2*N*NCYC)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED errors=%0d passes=%0d", errors, passes);

        $finish;
    end

endmodule
