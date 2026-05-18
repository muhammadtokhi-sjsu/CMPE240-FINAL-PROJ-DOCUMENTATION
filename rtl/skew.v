module skew #(
    parameter WIDTH = 8,
    parameter N = 8,
    parameter DIR = 0
) (
    input wire clk,
    input wire rst,
    input wire [N*WIDTH-1:0] d_in,
    output wire [N*WIDTH-1:0] d_out
);

    genvar i;

    generate
        for (i = 0; i < N; i = i + 1) begin : lane
            delay_line #(
                .WIDTH (WIDTH),
                .DEPTH ((DIR == 0) ? i : (N - 1 - i))
            ) u_dl (
                .clk (clk),
                .rst (rst),
                .d_in (d_in[i*WIDTH +: WIDTH]),
                .d_out (d_out[i*WIDTH +: WIDTH])
            );
        end
    endgenerate

endmodule
