`timescale 1ns / 1ps

module pe_tb;

    localparam IN_W = 8;
    localparam ACC_W = 32;

    reg clk;
    reg rst;
    reg w_load;
    reg signed [IN_W-1:0] w_in;
    reg signed [IN_W-1:0] act_in;
    reg signed [ACC_W-1:0] psum_in;
    wire signed [IN_W-1:0] w_out;
    wire signed [IN_W-1:0] act_out;
    wire signed [ACC_W-1:0] psum_out;

    integer errors;

    pe #(.IN_W(IN_W), .ACC_W(ACC_W)) dut (
        .clk (clk),
        .rst (rst),
        .w_load (w_load),
        .w_in (w_in),
        .act_in (act_in),
        .psum_in (psum_in),
        .w_out (w_out),
        .act_out (act_out),
        .psum_out (psum_out)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task load_weight;
        input signed [IN_W-1:0] value;
        begin
            @(negedge clk);
            w_load = 1'b1;
            w_in = value;
            @(negedge clk);
            w_load = 1'b0;
            w_in = {IN_W{1'b0}};
        end
    endtask

    task weight_check;
        input signed [IN_W-1:0] exp_w;
        begin
            if (w_out !== exp_w) begin
                errors = errors + 1;
                $display("FAIL t=%0t w_out=%0d expected=%0d", $time, w_out, exp_w);
            end else begin
                $display("PASS t=%0t w_out=%0d", $time, w_out);
            end
        end
    endtask

    task mac_check;
        input signed [IN_W-1:0] a;
        input signed [ACC_W-1:0] p;
        input signed [ACC_W-1:0] exp_psum;
        begin
            @(negedge clk);
            act_in = a;
            psum_in = p;
            @(posedge clk);
            #1;
            if (psum_out !== exp_psum) begin
                errors = errors + 1;
                $display("FAIL t=%0t psum_out=%0d expected=%0d", $time, psum_out, exp_psum);
            end else begin
                $display("PASS t=%0t psum_out=%0d", $time, psum_out);
            end
            if (act_out !== a) begin
                errors = errors + 1;
                $display("FAIL t=%0t act_out=%0d expected=%0d", $time, act_out, a);
            end
        end
    endtask

    task reset_check;
        begin
            @(negedge clk);
            rst = 1'b1;
            @(posedge clk);
            #1;
            if (psum_out !== {ACC_W{1'b0}} || act_out !== {IN_W{1'b0}}) begin
                errors = errors + 1;
                $display("FAIL t=%0t reset psum_out=%0d act_out=%0d", $time, psum_out, act_out);
            end else begin
                $display("PASS t=%0t reset", $time);
            end
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    initial begin
        errors = 0;
        rst = 1'b1;
        w_load = 1'b0;
        w_in = {IN_W{1'b0}};
        act_in = {IN_W{1'b0}};
        psum_in = {ACC_W{1'b0}};

        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;

        load_weight(8'sd3);
        weight_check(8'sd3);
        mac_check(8'sd5, 32'sd10, 32'sd25);
        mac_check(-8'sd4, 32'sd100, 32'sd88);

        load_weight(-8'sd7);
        weight_check(-8'sd7);
        mac_check(8'sd6, 32'sd0, -32'sd42);
        mac_check(-8'sd3, -32'sd5, 32'sd16);

        load_weight(8'sh80);
        weight_check(8'sh80);
        mac_check(8'sh80, 32'sd0, 32'sd16384);

        load_weight(8'sd127);
        weight_check(8'sd127);
        mac_check(8'sd127, 32'sd0, 32'sd16129);

        reset_check;

        load_weight(8'sd10);
        weight_check(8'sd10);
        mac_check(8'sd9, 32'sd1, 32'sd91);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED errors=%0d", errors);

        $finish;
    end

endmodule
