module pwm_driver #(
        parameter int PWM_MAX_ON_CYCLES = 1,
        parameter int DATA_WIDTH = 16
    ) (
        input  wire                  clk,
        input  wire                  reset,
        input  wire                  trigger,
        input  wire                  fault,
        input  wire [DATA_WIDTH-1:0] pwm_sink_data,
        input  wire                  pwm_sink_valid,
        input  wire [2:0]            sensor_hall_uvw,
        input  wire                  driver_otw_n,
        input  wire                  driver_fault_n,
        output reg  [2:0]            driver_pwm,
        output reg  [2:0]            driver_reset_n,
        output wire                  status_driver_otw_n,
        output wire                  status_driver_fault_n,
        output wire                  status_hall_fault_n
    );
    
    localparam int PWM_COUNTER_WIDTH = $clog2(PWM_MAX_ON_CYCLES + 1);
    
    // Filter nFAULT, nOTW
    deglitch #(
        .COUNTER_VALUE(15),
        .DEFAULT_LOGIC(1)
    ) deglitch_0 (
         .clk (clk),
        .in  (driver_otw_n),
        .out (status_driver_otw_n)
    );
    deglitch #(
        .COUNTER_VALUE(15),
        .DEFAULT_LOGIC(1)
    ) deglitch_1 (
        .clk (clk),
        .in  (driver_fault_n),
        .out (status_driver_fault_n)
    );
    
    // Commutation
    wire comm_direction = pwm_sink_data[$bits(pwm_sink_data)-1];
    wire [2:0] comm_input = sensor_hall_uvw ^ {3{comm_direction}};
    logic [2:0] comm_phase_enable;
    logic [2:0] comm_phase_polarity;
    assign status_hall_fault_n = (comm_phase_enable != 3'b000) & (comm_phase_polarity != 3'b111);
    always @(posedge clk, posedge reset) begin
        if (reset == 1'b1) begin
            comm_phase_enable <= 3'b000;
            comm_phase_polarity <= 3'b000;
        end
        else begin
            if (trigger == 1'b1) begin
                case (comm_input)
                    3'b100  : begin comm_phase_enable <= 3'b101; comm_phase_polarity <= 3'b100; end
                    3'b110  : begin comm_phase_enable <= 3'b011; comm_phase_polarity <= 3'b010; end
                    3'b010  : begin comm_phase_enable <= 3'b110; comm_phase_polarity <= 3'b010; end
                    3'b011  : begin comm_phase_enable <= 3'b101; comm_phase_polarity <= 3'b001; end
                    3'b001  : begin comm_phase_enable <= 3'b011; comm_phase_polarity <= 3'b001; end
                    3'b101  : begin comm_phase_enable <= 3'b110; comm_phase_polarity <= 3'b100; end
                    default : begin comm_phase_enable <= 3'b000; comm_phase_polarity <= 3'b000; end
                endcase
            end
        end
    end
    
    // Latch Next PWM Compare Value
    logic trigger_delayed = 1'b0;
    wire unsigned [DATA_WIDTH-1:0] pwm_sink_data_abs = (comm_direction == 1'b0) ? pwm_sink_data : -pwm_sink_data;
    logic unsigned [PWM_COUNTER_WIDTH-1:0] next_pwm_compare = '0;
    logic next_pwm_available = 1'b0;
    always @(posedge clk) begin
        trigger_delayed <= trigger;
    end
    always @(posedge clk, posedge reset) begin
        if (reset == 1'b1) begin
            next_pwm_compare <= '0;
            next_pwm_available <= 1'b0;
        end
        else if (fault | ~status_driver_otw_n | ~status_driver_fault_n) begin
            next_pwm_available <= 1'b0;
        end
        else if (pwm_sink_valid == 1'b1) begin
            next_pwm_compare <= (pwm_sink_data_abs < PWM_MAX_ON_CYCLES) ? PWM_COUNTER_WIDTH'(pwm_sink_data_abs) : PWM_COUNTER_WIDTH'(PWM_MAX_ON_CYCLES);
            next_pwm_available <= 1'b1;
        end
        else if (trigger_delayed == 1'b1) begin
            next_pwm_available <= 1'b0;
        end
    end
    
    // PWM wave Generation
    logic [2:0] driver_pwm_ff = '0;
    logic [2:0] driver_reset_n_ff = '0;
    logic pwm_drive = 1'b0;
    logic unsigned [PWM_COUNTER_WIDTH-1:0] pwm_compare = '0;
    logic unsigned [PWM_COUNTER_WIDTH-1:0] pwm_counter = '0;
    always @(posedge clk, posedge reset) begin
        if (reset == 1'b1) begin
            driver_pwm <= '0;
            driver_reset_n <= '0;
            driver_pwm_ff <= '0;
            driver_reset_n_ff <= '0;
            pwm_drive <= 1'b0;
            pwm_compare <= '0;
            pwm_counter <= '0;
        end
        else begin
            if (fault | ~status_driver_otw_n | ~status_driver_fault_n) begin
                pwm_drive <= 1'b0;
            end
            else if (trigger_delayed == 1'b1) begin
                if (next_pwm_available == 1'b1) begin
                    pwm_drive <= 1'b1;
                    pwm_compare <= next_pwm_compare;
                end
                pwm_counter <= '0;
            end
            else begin
                pwm_counter <= (pwm_counter < '1) ? pwm_counter + 1'b1 : '1;
            end
            driver_pwm_ff[0] <= pwm_drive & comm_phase_polarity[0] & (pwm_counter < pwm_compare);
            driver_pwm_ff[1] <= pwm_drive & comm_phase_polarity[1] & (pwm_counter < pwm_compare);
            driver_pwm_ff[2] <= pwm_drive & comm_phase_polarity[2] & (pwm_counter < pwm_compare);
            driver_reset_n_ff[0] <= pwm_drive & comm_phase_enable[0];
            driver_reset_n_ff[1] <= pwm_drive & comm_phase_enable[1];
            driver_reset_n_ff[2] <= pwm_drive & comm_phase_enable[2];
            driver_pwm <= driver_pwm_ff;
            driver_reset_n <= driver_reset_n_ff;
        end
    end
endmodule
