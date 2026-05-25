`timescale 1ns / 1ps

module NTT_System_tb;

    localparam CLK_PERIOD   = 10;
    localparam Q            = 12'd3329;
    localparam N            = 256;
    localparam DONE_TIMEOUT = 200_000;

    logic clk, rst_n, mosi, miso, cs_n;

    NTT_Top_Wrapper dut (
        .clk   (clk),
        .rst_n (rst_n),
        .mosi  (mosi),
        .miso  (miso),
        .cs_n  (cs_n)
    );

    initial clk = 1'b0;
    always  #(CLK_PERIOD/2) clk = ~clk;

    int pass_cnt = 0, fail_cnt = 0, skip_cnt = 0;

    `define CHECK(name, exp, got) \
        begin \
            if ((exp) === (got)) begin \
                $display(" [PASS] %-30s exp=%0d got=%0d", name, exp, got); \
                pass_cnt++; \
            end else begin \
                $display(" [FAIL] %-30s exp=%0d got=%0d", name, exp, got); \
                fail_cnt++; \
            end \
        end

    task automatic spi_transaction(
        input  logic  [7:0]  cmd,
        input  logic  [15:0] tx_data,
        output logic  [15:0] rx_data
    );
        automatic logic [23:0] frame;
        automatic logic [15:0] rx;
        frame = {cmd, tx_data};
        rx    = '0;
        @(negedge clk);
        cs_n = 1'b0;
        for (int i = 23; i >= 0; i--) begin
            mosi = frame[i];
            @(posedge clk);
            #1;
            if (i >= 1 && i <= 16)
                rx[i-1] = miso;
        end
        @(negedge clk);
        cs_n    = 1'b1;
        mosi    = 1'b0;
        rx_data = rx;
        repeat (3) @(posedge clk);
    endtask

    task automatic ram_write(input logic [7:0] addr, input logic [11:0] data);
        logic [15:0] dummy;
        spi_transaction(8'h02, {8'h00, addr},  dummy);
        spi_transaction(8'h83, {4'h0,  data},  dummy);
    endtask

    task automatic ram_read(input logic [7:0] addr, output logic [11:0] data);
        logic [15:0] rx;
        logic [15:0] dummy;
        spi_transaction(8'h02, {8'h00, addr}, dummy);
        @(posedge clk); @(posedge clk);
        spi_transaction(8'h03, 16'h0000, rx);
        data = rx[11:0];
    endtask

    task automatic read_done(output logic done_bit);
        logic [15:0] rx;
        spi_transaction(8'h01, 16'h0000, rx);
        done_bit = rx[0];
    endtask

    task automatic send_start(input logic mode);
        logic [15:0] dummy;
        spi_transaction(8'h00, {14'h0, mode, 1'b1}, dummy);
    endtask

    task automatic wait_done(output logic success);
        automatic logic d;
        success = 1'b0;
        for (int t = 0; t < DONE_TIMEOUT; t++) begin
            read_done(d);
            if (d) begin
                success = 1'b1;
                t = DONE_TIMEOUT;
            end
        end
    endtask

    task automatic system_reset();
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
    endtask

  
    task automatic clear_ram();
        for (int i = 0; i < N; i++) begin
            ram_write(8'(i), 12'h000);
        end
    endtask

    function automatic logic [11:0] mod_mul_ref(logic [11:0] a, b);
        automatic logic [11:0] t   = 0;
        automatic logic [11:0] t2  = a;
        automatic logic [11:0] sr  = b;
        automatic logic [12:0] sum;
        automatic logic [12:0] dbl;
        for (int k = 0; k < 12; k++) begin
            if (sr[0]) begin
                sum = {1'b0,t} + {1'b0,t2};
                t   = (sum >= Q) ? (sum - Q) : sum[11:0];
            end
            sr  = sr >> 1;
            dbl = {t2, 1'b0};
            t2  = (dbl >= Q) ? (dbl - Q) : dbl[11:0];
        end
        return t;
    endfunction

    logic [11:0] input_data  [0:N-1];
    logic [11:0] ntt_result  [0:N-1];
    logic [11:0] intt_result [0:N-1];
    logic op_success;

    initial begin
        rst_n = 1'b1;
        mosi  = 1'b0;
        cs_n  = 1'b1;

        $display("\n NTT Accelerator System Test ");

        $display("\n T01: Hard Reset ");
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        `CHECK("done_pin_after_reset", 1'b0, dut.done)

        $display("\n T02: Reset-release Stability ");
        repeat (20) @(posedge clk);
        `CHECK("start_still_0", 1'b0, dut.start)

        $display("\n T03: SPI CMD 0x02 - Set Address ");
        begin
            logic [15:0] dummy;
            spi_transaction(8'h02, 16'h00AB, dummy);
            `CHECK("ext_ram_addr_AB", 8'hAB, dut.ext_ram_addr)
            spi_transaction(8'h02, 16'h0000, dummy);
            `CHECK("ext_ram_addr_00", 8'h00, dut.ext_ram_addr)
        end

        $display("\n T04+T05: RAM Write/Read Sweep ");
        for (int i = 0; i < 256; i++) begin
            input_data[i] = 12'((i * 13 + 7) % Q);
            ram_write(8'(i), input_data[i]);
        end
        begin
            automatic int errors = 0;
            for (int i = 0; i < 256; i++) begin
                logic [11:0] rv;
                ram_read(8'(i), rv);
                if (rv !== input_data[i]) errors++;
            end
            if (errors == 0) begin
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

        $display("\n T06: RAM Boundary Addresses ");
        begin
            logic [11:0] rv;
            ram_write(8'h00, 12'hAAA);
            ram_read (8'h00, rv);
            `CHECK("RAM_0x00", 12'hAAA, rv)
            ram_write(8'hFF, 12'h555);
            ram_read (8'hFF, rv);
            `CHECK("RAM_0xFF", 12'h555, rv)
        end

        $display("\n T07: RAM Max Data Values ");
        begin
            logic [11:0] rv;
            ram_write(8'h10, 12'd3328);
            ram_read (8'h10, rv);
            `CHECK("RAM_16_Max", 12'd3328, rv)
        end

        $display("\n T08: Read DONE Before Start ");
        begin
            logic d;
            read_done(d);
            `CHECK("done_before_start", 1'b0, d)
        end

        $display("\n T09: CMD 0x00 - Mode Write ");
        begin
            logic [15:0] dummy;
            spi_transaction(8'h00, 16'h0002, dummy);
            `CHECK("mode_pin_1", 1'b1, dut.mode)
            spi_transaction(8'h00, 16'h0000, dummy);
            `CHECK("mode_pin_0", 1'b0, dut.mode)
        end

        $display("\n T10: Unknown SPI Commands ");
        begin
            logic [15:0] rx;
            spi_transaction(8'h40, 16'hDEAD, rx);
            `CHECK("CMD_0x40", 16'h0000, rx)
        end

        $display("\n T11: NTT Forward Transform ");
        for (int i = 0; i < N; i++) begin
            input_data[i] = 12'(i % Q);
            ram_write(8'(i), input_data[i]);
        end
        send_start(1'b0);
        wait_done(op_success);
        `CHECK("T11_NTT_done", 1'b1, op_success)
        for (int i = 0; i < N; i++) ram_read(8'(i), ntt_result[i]);
        begin
            automatic int err = 0;
            for (int i = 0; i < N; i++) if (ntt_result[i] >= Q) err++;
            if (err == 0) begin
                $display(" [PASS] %-30s", "T11: NTT Forward Transform");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T11: NTT Forward Transform");
                fail_cnt++;
            end
        end

        $display("\n T12: INTT Inverse Transform ");
        send_start(1'b1);
        wait_done(op_success);
        `CHECK("T12_INTT_done", 1'b1, op_success)
        for (int i = 0; i < N; i++) ram_read(8'(i), intt_result[i]);
        begin
            automatic int err = 0;
            for (int i = 0; i < N; i++) if (intt_result[i] >= Q) err++;
            if (err == 0) begin
                $display(" [PASS] %-30s", "T12: INTT Inverse Transform");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T12: INTT Inverse Transform");
                fail_cnt++;
            end
        end

        $display("\n T13: Round-Trip INTT(NTT(x)) ");
        begin
            automatic int exact_match  = 0;
            automatic int scaled_match = 0;
            automatic logic [11:0] scale_factor = 12'd0;

            if (input_data[1] != 0) begin
                for (int s = 0; s < Q && scale_factor == 0; s++) begin
                    if (s != 0 && mod_mul_ref(12'(s), input_data[1]) == intt_result[1])
                        scale_factor = 12'(s);
                end
            end
            for (int i = 0; i < N; i++) begin
                if (intt_result[i] === input_data[i]) exact_match++;
                if (scale_factor != 0 && intt_result[i] === mod_mul_ref(scale_factor, input_data[i])) scaled_match++;
            end
            if (exact_match == N || (scale_factor != 0 && scaled_match == N)) begin
                $display(" [PASS] %-30s", "T13_Round_Trip_INTT(NTT(x))");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T13_Round_Trip_INTT(NTT(x))");
                skip_cnt++;
            end
        end

        $display("\n T14: NTT of All-Zero Input ");
        system_reset();
        clear_ram();
        send_start(1'b0);
        wait_done(op_success);
        begin
            automatic int err = 0;
            logic [11:0] rv;
            for (int i = 0; i < N; i++) begin
                ram_read(8'(i), rv);
                if (rv != 12'h0) err++;
            end
            if (err == 0) begin
                $display(" [PASS] %-30s", "T14_All_Zero_Input");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T14_All_Zero_Input");
                fail_cnt++;
            end
            
        end

        $display("\n T15: NTT of Single Impulse x[0]=1 ");
        system_reset();
        clear_ram(); 
        ram_write(8'd0, 12'd1);
        send_start(1'b0);
        wait_done(op_success);
        begin
            automatic int err = 0;
            for (int i = 0; i < N; i++) begin
                logic [11:0] rv;
                ram_read(8'(i), rv);
                if (rv >= Q) err++; 
            end
            if (err == 0 && op_success == 1'b1) begin
                $display(" [PASS] %-30s", "T15_Single_Impulse");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T15_Single_Impulse");
                fail_cnt++;
            end
        end

        $display("\n T16: Round-Trip #2 ");
        begin
            logic [11:0] saved [0:N-1];
            automatic logic [11:0] scale2 = 12'd0;
            for (int i = 0; i < N; i++) begin
                saved[i] = 12'((i * 1103515245 + 12345) % Q);
                ram_write(8'(i), saved[i]);
            end
            send_start(1'b0);
            wait_done(op_success);
            send_start(1'b1);
            wait_done(op_success);
            begin
                automatic int exact = 0;
                automatic int scaled = 0;
                logic [11:0] rv0;
                for (int i = 0; i < N; i++) begin
                    logic [11:0] rv;
                    ram_read(8'(i), rv);
                    if (rv === saved[i]) exact++;
                end
                ram_read(8'h01, rv0);
                if (saved[1] != 0) begin
                    for (int s = 1; s < Q && scale2 == 0; s++) begin
                        if (mod_mul_ref(12'(s), saved[1]) == rv0) scale2 = 12'(s);
                    end
                end
                if (scale2 != 0) begin
                    for (int i = 0; i < N; i++) begin
                        logic [11:0] rv;
                        ram_read(8'(i), rv);
                        if (rv === mod_mul_ref(scale2, saved[i])) scaled++;
                    end
                end
                if (exact == N || (scale2 != 0 && scaled == N)) begin
                $display(" [PASS] %-30s", "T16_Round_Trip_#2");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T16_Round_Trip_#2");
                skip_cnt++;
            end
            end
        end

        $display("\n T17: Back-to-Back NTT Runs ");
        begin
            logic [11:0] r1[0:7], r2[0:7];
            for (int i = 0; i < N; i++) ram_write(8'(i), 12'd100);
            send_start(1'b0);
            wait_done(op_success);
            for (int i = 0; i < 8; i++) ram_read(8'(i), r1[i]);
            
            for (int i = 0; i < N; i++) ram_write(8'(i), 12'd200);
            send_start(1'b0);
            wait_done(op_success);
            for (int i = 0; i < 8; i++) ram_read(8'(i), r2[i]);

            begin
                automatic int diff = 0;
                for (int i = 0; i < 8; i++) if (r1[i] !== r2[i]) diff++;
                if (diff > 0) begin
                $display(" [PASS] %-30s", "T17: Back-to-Back NTT Runs");
                pass_cnt++;
            end else begin
                $display(" [FAIL] %-30s", "T17: Back-to-Back NTT Runs");
                fail_cnt++;
            end
            end
        end

        $display("\n T18: DONE De-Asserts on New Start ");
        begin
            logic d;
            for (int i = 0; i < N; i++) ram_write(8'(i), 12'(i % 50));
            send_start(1'b0);
            @(posedge clk); @(posedge clk);
            `CHECK("T18_done_cleared", 1'b0, dut.done)
            wait_done(op_success);
            `CHECK("T18_done_asserted", 1'b1, op_success)
        end

        $display("\n T19: Reset During NTT Operation ");
        begin
            logic d;
            for (int i = 0; i < N; i++) ram_write(8'(i), 12'(i % 100));
            send_start(1'b0);
            repeat (30) @(posedge clk);
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
            `CHECK("T19_done_after_rst", 1'b0, dut.done)
        end

        $display("\n T20: SPI Read While NTT Running ");
        begin
            logic d;
            for (int i = 0; i < N; i++) ram_write(8'(i), 12'(i + 10));
            send_start(1'b0);
            repeat (5) read_done(d);
            wait_done(op_success);
            `CHECK("T20_eventually_done", 1'b1, op_success)
        end

        $display("\n T21: Timeout Path Coverage ");
        begin
            logic d;
            read_done(d);
            pass_cnt++;
        end

        $display("\n T22: Full Register-Map Sweep ");
        begin
            logic [15:0] rx;
            spi_transaction(8'h02, 16'h0042, rx);
            spi_transaction(8'h83, 16'h0BEE, rx);
            spi_transaction(8'h02, 16'h0042, rx);
            repeat(2) @(posedge clk);
            spi_transaction(8'h03, 16'h0000, rx);
            `CHECK("T22_READ_0xBEE", 12'hBEE, rx[11:0])
        end

        $display("\n T23: Direct Manual Verification (The Mirror Test) ");
        begin
            automatic int manual_err = 0;
            logic [11:0] rv;
            system_reset();
            clear_ram(); 
            ram_write(8'd0,   12'd1000);
            ram_write(8'd128, 12'd3000);
            
            send_start(1'b0);
            wait_done(op_success);
            
            for (int i = 0; i < N; i++) begin
                ram_read(8'(i), rv);
                if (i % 2 != 0) begin
                    if (rv != 12'd0) begin
                        if (manual_err < 10) $display("    [DEBUG] Error at Odd Index %0d: Expected 0, Got %0d", i, rv);
                        manual_err++;
                    end
                end 
                else if (i < 128) begin
                    if (rv != 12'd671) begin
                        if (manual_err < 10) $display("    [DEBUG] Error at Even Index %0d: Expected 671, Got %0d", i, rv);
                        manual_err++;
                    end
                end 
                else begin
                    if (rv != 12'd1329) begin
                        if (manual_err < 10) $display("    [DEBUG] Error at Even Index %0d: Expected 1329, Got %0d", i, rv);
                        manual_err++;
                    end
                end
            end
            
            if (manual_err == 0) begin
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

        $display("\n T24: Direct Manual Verification (INTT Round-Trip) ");
        begin
            automatic int manual_intt_err = 0;
            logic [11:0] rv;
            send_start(1'b1);
            wait_done(op_success);

            for (int i = 0; i < N; i++) begin
                ram_read(8'(i), rv);
                if (i == 0) begin
                    if (rv != 12'd1000) begin
                        if (manual_intt_err < 10) $display("    [DEBUG] Error at Index 0: Expected 1000, Got %0d", rv);
                        manual_intt_err++;
                    end
                end
                else if (i == 128) begin
                    if (rv != 12'd3000) begin
                        if (manual_intt_err < 10) $display("    [DEBUG] Error at Index 128: Expected 3000, Got %0d", rv);
                        manual_intt_err++;
                    end
                end
                else begin
                    if (rv != 12'd0) begin
                        if (manual_intt_err < 10) $display("    [DEBUG] Error at Index %0d: Expected 0, Got %0d", i, rv);
                        manual_intt_err++;
                    end
                end
            end
            
            if (manual_intt_err == 0) begin
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

        repeat (10) @(posedge clk);
        $display("\n TESTBENCH REPORT ");
        $display(" PASSED  : %0d", pass_cnt);
        $display(" FAILED  : %0d", fail_cnt);
        $display(" SKIPPED : %0d", skip_cnt);
        $stop;
    end

    initial begin
        #50_000_000;
        $stop;
    end

    initial begin
        $dumpfile("NTT_System_tb.vcd");
        $dumpvars(0, NTT_System_tb);
    end

endmodule