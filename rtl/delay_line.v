module delay_line #(
    parameter WIDTH = 8,
    parameter DEPTH = 0
) (
    input wire clk,
    input wire rst,
    input wire [WIDTH-1:0] d_in,
    output wire [WIDTH-1:0] d_out
);

    generate
        if (DEPTH == 0) begin : g_passthrough

            assign d_out = d_in;

        end else begin : g_shift

            reg [WIDTH-1:0] sr [0:DEPTH-1];
            integer i;

            always @(posedge clk) begin
                if (rst) begin
                    for (i = 0; i < DEPTH; i = i + 1)
                        sr[i] <= {WIDTH{1'b0}};
                end else begin
                    sr[0] <= d_in;
                    for (i = 1; i < DEPTH; i = i + 1)
                        sr[i] <= sr[i-1];
                end
            end

            assign d_out = sr[DEPTH-1];

        end
    endgenerate

endmodule
