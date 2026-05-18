(* use_dsp = "yes" *)
module pe #(
    parameter IN_W = 8,
    parameter ACC_W = 32
) (
    input wire clk,
    input wire rst,
    input wire w_load,
    input wire signed [IN_W-1:0] w_in,
    input wire signed [IN_W-1:0] act_in,
    input wire signed [ACC_W-1:0] psum_in,
    output wire signed [IN_W-1:0] w_out,
    output reg signed [IN_W-1:0] act_out,
    output reg signed [ACC_W-1:0] psum_out
);

    reg signed [IN_W-1:0] weight;
    wire signed [2*IN_W-1:0] product;

    assign product = weight * act_in;
    assign w_out = weight;

    always @(posedge clk) begin
        if (rst)
            weight <= {IN_W{1'b0}};
        else if (w_load)
            weight <= w_in;
    end

    always @(posedge clk) begin
        if (rst) begin
            act_out <= {IN_W{1'b0}};
            psum_out <= {ACC_W{1'b0}};
        end else begin
            act_out <= act_in;
            psum_out <= psum_in + product;
        end
    end

endmodule
