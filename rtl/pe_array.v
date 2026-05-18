module pe_array #(
    parameter IN_W = 8,
    parameter ACC_W = 32,
    parameter N = 8
) (
    input wire clk,
    input wire rst,
    input wire w_load,
    input wire signed [N*IN_W-1:0] w_in,
    input wire signed [N*IN_W-1:0] act_in,
    output wire signed [N*ACC_W-1:0] psum_out
);

    wire signed [IN_W-1:0] act_wire [0:N-1][0:N-1];
    wire signed [IN_W-1:0] w_wire [0:N-1][0:N-1];
    wire signed [ACC_W-1:0] psum_wire [0:N-1][0:N-1];

    genvar r, c;

    generate
        for (r = 0; r < N; r = r + 1) begin : row
            for (c = 0; c < N; c = c + 1) begin : col

                wire signed [IN_W-1:0] pe_w_in;
                wire signed [IN_W-1:0] pe_act_in;
                wire signed [ACC_W-1:0] pe_psum_in;

                if (r == 0)
                    assign pe_w_in = $signed(w_in[c*IN_W +: IN_W]);
                else
                    assign pe_w_in = w_wire[r-1][c];

                if (c == 0)
                    assign pe_act_in = $signed(act_in[r*IN_W +: IN_W]);
                else
                    assign pe_act_in = act_wire[r][c-1];

                if (r == 0)
                    assign pe_psum_in = {ACC_W{1'b0}};
                else
                    assign pe_psum_in = psum_wire[r-1][c];

                pe #(
                    .IN_W (IN_W),
                    .ACC_W (ACC_W)
                ) u_pe (
                    .clk (clk),
                    .rst (rst),
                    .w_load (w_load),
                    .w_in (pe_w_in),
                    .act_in (pe_act_in),
                    .psum_in (pe_psum_in),
                    .w_out (w_wire[r][c]),
                    .act_out (act_wire[r][c]),
                    .psum_out (psum_wire[r][c])
                );

            end
        end
    endgenerate

    generate
        for (c = 0; c < N; c = c + 1) begin : out_map
            assign psum_out[c*ACC_W +: ACC_W] = psum_wire[N-1][c];
        end
    endgenerate

endmodule
