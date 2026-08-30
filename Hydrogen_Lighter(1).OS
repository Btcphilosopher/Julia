// ============================================================
// SILICAFLUX DEVICE DEFINITION
// H2-LIGHTER.OS
// ============================================================

DEVICE HydrogenLighter
VERSION "1.0.0"

DESCRIPTION """
Premium refillable hydrogen lighter controller.
Safety-first deterministic architecture.
"""

// ------------------------------------------------------------
// INPUTS
// ------------------------------------------------------------

INPUT battery_ok       : BOOL
INPUT safety_closed    : BOOL
INPUT gas_detected     : BOOL

// Extended diagnostic inputs
INPUT temperature_ok   : BOOL
INPUT pressure_ok      : BOOL
INPUT flame_detected   : BOOL

// ------------------------------------------------------------
// OUTPUTS
// ------------------------------------------------------------

OUTPUT status          : ENUM {
    READY,
    LOCKED,
    IGNITING,
    BURNING,
    COOLING,
    FAULT
}

OUTPUT hydrogen_enable : BOOL
OUTPUT ignition_enable : BOOL

// ------------------------------------------------------------
// FUNDAMENTAL SAFETY CONTRACT
// ------------------------------------------------------------

RULE SAFE_TO_ARM:

    battery_ok
    AND safety_closed
    AND NOT gas_detected
    AND temperature_ok
    AND pressure_ok

// ------------------------------------------------------------
// DEFAULT STATE
// ------------------------------------------------------------

STATE OFF

// ------------------------------------------------------------
// READY
// ------------------------------------------------------------

WHEN SAFE_TO_ARM
    status = READY
    hydrogen_enable = FALSE
    ignition_enable = FALSE

// ------------------------------------------------------------
// EVERYTHING ELSE
// ------------------------------------------------------------

ELSE
    status = LOCKED
    hydrogen_enable = FALSE
    ignition_enable = FALSE

// ------------------------------------------------------------
// HARD FAIL-SAFE
// ------------------------------------------------------------

ON gas_detected
    hydrogen_enable = FALSE
    ignition_enable = FALSE
    status = FAULT

ON NOT safety_closed
    hydrogen_enable = FALSE
    ignition_enable = FALSE
    status = LOCKED

ON NOT battery_ok
    hydrogen_enable = FALSE
    ignition_enable = FALSE
    status = LOCKED

ON NOT temperature_ok
    hydrogen_enable = FALSE
    ignition_enable = FALSE
    status = FAULT

ON NOT pressure_ok
    hydrogen_enable = FALSE
    ignition_enable = FALSE
    status = FAULT
    // ============================================================
// H2-LIGHTER.OS
// HARDWARE SAFETY CORE
//
// SystemVerilog
// ============================================================

module hydrogen_lighter_safety (

    input  logic clk,
    input  logic reset_n,

    input  logic battery_ok,
    input  logic safety_closed,
    input  logic gas_detected,

    input  logic temperature_ok,
    input  logic pressure_ok,

    input  logic flame_detected,

    input  logic ignition_request,
    input  logic stop_request,

    output logic ready,
    output logic locked,
    output logic fault,

    output logic hydrogen_enable,
    output logic ignition_enable,

    output logic flame_valid

);


    // ========================================================
    // INTERNAL SAFETY CONDITION
    // ========================================================

    logic safe_to_arm;


    always_comb begin

        safe_to_arm =

            battery_ok
            &&
            safety_closed
            &&
            !gas_detected
            &&
            temperature_ok
            &&
            pressure_ok;

    end


    // ========================================================
    // FLAME VALIDATION
    // ========================================================

    always_comb begin

        flame_valid =

            flame_detected
            &&
            safety_closed
            &&
            !gas_detected
            &&
            temperature_ok
            &&
            pressure_ok;

    end


    // ========================================================
    // HARDWARE SAFETY OUTPUTS
    //
    // Any invalid safety condition dominates normal operation.
    // ========================================================

    always_comb begin

        hydrogen_enable = 1'b0;
        ignition_enable = 1'b0;

        ready  = 1'b0;
        locked = 1'b0;
        fault  = 1'b0;


        // ----------------------------------------------------
        // GAS DETECTED = HARD FAULT
        // ----------------------------------------------------

        if (gas_detected) begin

            fault = 1'b1;

        end


        // ----------------------------------------------------
        // THERMAL / PRESSURE FAULT
        // ----------------------------------------------------

        else if (!temperature_ok ||
                 !pressure_ok) begin

            fault = 1'b1;

        end


        // ----------------------------------------------------
        // BASIC LOCK
        // ----------------------------------------------------

        else if (!battery_ok ||
                 !safety_closed) begin

            locked = 1'b1;

        end


        // ----------------------------------------------------
        // READY
        // ----------------------------------------------------

        else if (safe_to_arm) begin

            ready = 1'b1;

        end

    end


    // ========================================================
    // OUTPUT CONTROL
    //
    // Hardware safety conditions always override requests.
    // ========================================================

    always_ff @(posedge clk or negedge reset_n) begin

        if (!reset_n) begin

            hydrogen_enable <= 1'b0;
            ignition_enable <= 1'b0;

        end

        else begin

            // ------------------------------------------------
            // ABSOLUTE SAFETY OVERRIDE
            // ------------------------------------------------

            if (!safe_to_arm) begin

                hydrogen_enable <= 1'b0;
                ignition_enable <= 1'b0;

            end

            // ------------------------------------------------
            // STOP
            // ------------------------------------------------

            else if (stop_request) begin

                hydrogen_enable <= 1'b0;
                ignition_enable <= 1'b0;

            end

            // ------------------------------------------------
            // IGNITION REQUEST
            // ------------------------------------------------

            else if (ignition_request) begin

                hydrogen_enable <= 1'b1;
                ignition_enable <= 1'b1;

            end

            // ------------------------------------------------
            // DEFAULT
            // ------------------------------------------------

            else begin

                hydrogen_enable <= 1'b0;
                ignition_enable <= 1'b0;

            end

        end

    end

endmodule
#![no_std]

// ============================================================
// H2-LIGHTER.OS
// EMBEDDED RUST FIRMWARE
// ============================================================

#[derive(
    Clone,
    Copy,
    PartialEq,
    Eq,
    Debug
)]
pub enum State {

    Off,

    Ready,

    Igniting,

    Burning,

    Cooling,

    Fault,
}


// ============================================================
// SENSOR SNAPSHOT
// ============================================================

#[derive(
    Clone,
    Copy,
    Debug
)]
pub struct Sensors {

    pub battery_ok: bool,

    pub safety_closed: bool,

    pub gas_detected: bool,

    pub temperature_ok: bool,

    pub pressure_ok: bool,

    pub flame_detected: bool,
}


// ============================================================
// OUTPUTS
// ============================================================

#[derive(
    Clone,
    Copy,
    Debug
)]
pub struct Outputs {

    pub hydrogen_enable: bool,

    pub ignition_enable: bool,

    pub status: State,
}


impl Outputs {

    pub const fn safe() -> Self {

        Self {

            hydrogen_enable: false,

            ignition_enable: false,

            status: State::Off,
        }
    }


    pub fn shutdown(
        &mut self
    ) {

        self.hydrogen_enable = false;

        self.ignition_enable = false;
    }
}


// ============================================================
// CONTROLLER
// ============================================================

pub struct HydrogenLighter {

    pub state: State,

    pub sensors: Sensors,

    pub outputs: Outputs,

    run_time_ms: u32,

    ignition_time_ms: u32,
}


// ============================================================
// CONSTANTS
// ============================================================

const MAX_IGNITION_TIME_MS: u32 = 5_000;

const MAX_BURN_TIME_MS: u32 = 5_000;


// ============================================================
// IMPLEMENTATION
// ============================================================

impl HydrogenLighter {

    pub const fn new() -> Self {

        Self {

            state: State::Off,

            sensors: Sensors {

                battery_ok: false,

                safety_closed: false,

                gas_detected: false,

                temperature_ok: false,

                pressure_ok: false,

                flame_detected: false,
            },

            outputs: Outputs::safe(),

            run_time_ms: 0,

            ignition_time_ms: 0,
        }
    }


    // ========================================================
    // EXACT SILICAFLUX SAFETY RULE
    // ========================================================

    fn basic_ready(
        &self
    ) -> bool {

        self.sensors.battery_ok
            &&
        self.sensors.safety_closed
            &&
        !self.sensors.gas_detected
    }


    // ========================================================
    // FULL HARDWARE SAFETY CONDITION
    // ========================================================

    fn safe_to_arm(
        &self
    ) -> bool {

        self.sensors.battery_ok
            &&
        self.sensors.safety_closed
            &&
        !self.sensors.gas_detected
            &&
        self.sensors.temperature_ok
            &&
        self.sensors.pressure_ok
    }


    // ========================================================
    // POWER ON
    // ========================================================

    pub fn power_on(
        &mut self
    ) {

        self.outputs.shutdown();

        self.run_time_ms = 0;

        self.ignition_time_ms = 0;

        self.state = State::Ready;
    }


    // ========================================================
    // IGNITION REQUEST
    // ========================================================

    pub fn ignite(
        &mut self
    ) -> bool {

        if self.state != State::Ready {

            return false;
        }


        if !self.safe_to_arm() {

            self.enter_fault();

            return false;
        }


        self.outputs.hydrogen_enable = true;

        self.outputs.ignition_enable = true;

        self.outputs.status = State::Igniting;

        self.ignition_time_ms = 0;

        self.run_time_ms = 0;

        self.state = State::Igniting;

        true
    }


    // ========================================================
    // STOP
    // ========================================================

    pub fn stop(
        &mut self
    ) {

        self.outputs.shutdown();

        self.state = State::Cooling;

        self.outputs.status = State::Cooling;
    }


    // ========================================================
    // FAULT
    // ========================================================

    fn enter_fault(
        &mut self
    ) {

        self.outputs.shutdown();

        self.state = State::Fault;

        self.outputs.status = State::Fault;
    }


    // ========================================================
    // MAIN CONTROL LOOP
    // ========================================================

    pub fn update(
        &mut self,
        elapsed_ms: u32
    ) {

        // ----------------------------------------------------
        // GLOBAL SAFETY
        // ----------------------------------------------------

        if !self.safe_to_arm() {

            if self.sensors.gas_detected ||
               !self.sensors.temperature_ok ||
               !self.sensors.pressure_ok {

                self.enter_fault();

            } else {

                self.outputs.shutdown();

                self.state = State::Off;

                self.outputs.status = State::Locked;
            }

            return;
        }


        // ----------------------------------------------------
        // STATE MACHINE
        // ----------------------------------------------------

        match self.state {

            State::Off => {

                self.outputs.shutdown();

                if self.basic_ready() {

                    self.state = State::Ready;

                    self.outputs.status =
                        State::Ready;
                }
            }


            State::Ready => {

                self.outputs.shutdown();

                self.outputs.status =
                    State::Ready;

                self.run_time_ms = 0;
            }


            State::Igniting => {

                self.ignition_time_ms =
                    self.ignition_time_ms
                    .saturating_add(elapsed_ms);


                if self.sensors.flame_detected {

                    self.outputs.ignition_enable =
                        false;

                    self.state =
                        State::Burning;

                    self.outputs.status =
                        State::Burning;

                    self.run_time_ms = 0;

                    return;
                }


                if self.ignition_time_ms >=
                   MAX_IGNITION_TIME_MS {

                    self.enter_fault();
                }
            }


            State::Burning => {

                self.run_time_ms =
                    self.run_time_ms
                    .saturating_add(elapsed_ms);


                // Flame loss = immediate fault.
                if !self.sensors.flame_detected {

                    self.enter_fault();

                    return;
                }


                // Maximum continuous operation.
                if self.run_time_ms >=
                   MAX_BURN_TIME_MS {

                    self.stop();

                    return;
                }


                self.outputs.status =
                    State::Burning;
            }


            State::Cooling => {

                self.outputs.shutdown();


                // Cooldown threshold would normally come
                // from a calibrated hardware sensor.

                if self.sensors.temperature_ok {

                    self.state =
                        State::Ready;

                    self.outputs.status =
                        State::Ready;
                }
            }


            State::Fault => {

                // Latched safe state.
                self.outputs.shutdown();

                self.outputs.status =
                    State::Fault;
            }
        }
    }


    // ========================================================
    // HARD RESET / SERVICE RECOVERY
    // ========================================================

    pub fn reset_fault(
        &mut self
    ) -> bool {

        if self.state != State::Fault {

            return true;
        }


        if !self.safe_to_arm() {

            return false;
        }


        self.outputs.shutdown();

        self.state = State::Ready;

        self.outputs.status =
            State::Ready;

        true
    }
}


// ============================================================
// TESTS
// ============================================================

#[cfg(test)]
mod tests {

    use super::*;


    fn safe_sensors() -> Sensors {

        Sensors {

            battery_ok: true,

            safety_closed: true,

            gas_detected: false,

            temperature_ok: true,

            pressure_ok: true,

            flame_detected: false,
        }
    }


    #[test]
    fn basic_rule_produces_ready() {

        let lighter =
            HydrogenLighter {

                state: State::Off,

                sensors: safe_sensors(),

                outputs: Outputs::safe(),

                run_time_ms: 0,

                ignition_time_ms: 0,
            };


        assert!(
            lighter.basic_ready()
        );

        assert!(
            lighter.safe_to_arm()
        );
    }


    #[test]
    fn gas_detection_blocks_operation() {

        let mut sensors =
            safe_sensors();

        sensors.gas_detected = true;


        let mut lighter =
            HydrogenLighter::new();

        lighter.sensors = sensors;

        lighter.power_on();

        lighter.update(1);


        assert_eq!(
            lighter.state,
            State::Fault
        );


        assert!(
            !lighter.outputs.hydrogen_enable
        );


        assert!(
            !lighter.outputs.ignition_enable
        );
    }


    #[test]
    fn open_safety_blocks_operation() {

        let mut sensors =
            safe_sensors();

        sensors.safety_closed = false;


        let mut lighter =
            HydrogenLighter::new();

        lighter.sensors = sensors;

        lighter.power_on();

        lighter.update(1);


        assert!(
            !lighter.outputs.hydrogen_enable
        );

        assert!(
            !lighter.outputs.ignition_enable
        );
    }


    #[test]
    fn successful_ignition_enters_burning() {

        let mut lighter =
            HydrogenLighter::new();

        lighter.sensors =
            safe_sensors();

        lighter.power_on();


        assert!(
            lighter.ignite()
        );


        lighter.sensors.flame_detected =
            true;


        lighter.update(10);


        assert_eq!(
            lighter.state,
            State::Burning
        );


        assert!(
            lighter.outputs.hydrogen_enable
        );


        assert!(
            !lighter.outputs.ignition_enable
        );
    }


    #[test]
    fn flame_loss_faults_system() {

        let mut lighter =
            HydrogenLighter::new();

        lighter.sensors =
            safe_sensors();

        lighter.power_on();

        lighter.ignite();


        lighter.sensors.flame_detected =
            true;

        lighter.update(10);


        lighter.sensors.flame_detected =
            false;

        lighter.update(10);


        assert_eq!(
            lighter.state,
            State::Fault
        );


        assert!(
            !lighter.outputs.hydrogen_enable
        );
    }


    #[test]
    fn emergency_condition_cannot_enable_output() {

        let mut lighter =
            HydrogenLighter::new();

        lighter.sensors =
            safe_sensors();

        lighter.power_on();


        lighter.sensors.gas_detected =
            true;


        lighter.update(1);


        assert!(
            !lighter.outputs.hydrogen_enable
        );

        assert!(
            !lighter.outputs.ignition_enable
        );

        assert_eq!(
            lighter.state,
            State::Fault
        );
    }
}
module HydrogenLighterOS

# ============================================================
# H2-LIGHTER.OS
# Burn Amount Selector
#
# Pure Julia
#
# The physical hardware should independently enforce safe
# gas/pressure/temperature limits. This software selector is
# only a bounded control input.
# ============================================================


# ============================================================
# BURN SWITCH
# ============================================================

@enum BurnAmount begin
    SHORT
    MEDIUM
    LONG
end


# ============================================================
# CONFIGURATION
# ============================================================

struct BurnProfile

    amount::BurnAmount
    duration_ms::UInt32

end


const BURN_PROFILES = (

    BurnProfile(
        SHORT,
        UInt32(500)
    ),

    BurnProfile(
        MEDIUM,
        UInt32(1000)
    ),

    BurnProfile(
        LONG,
        UInt32(2000)
    )
)


# ============================================================
# LOOKUP
# ============================================================

function profile(
    amount::BurnAmount
)::BurnProfile

    for p in BURN_PROFILES

        if p.amount == amount
            return p
        end

    end

    error("Invalid burn amount")

end


# ============================================================
# DIGITAL SWITCH
# ============================================================

mutable struct BurnSwitch

    selected::BurnAmount

end


BurnSwitch() =
    BurnSwitch(SHORT)


function set_burn!(
    switch::BurnSwitch,
    amount::BurnAmount
)

    switch.selected = amount

    return profile(amount)

end


function selected_profile(
    switch::BurnSwitch
)

    profile(
        switch.selected
    )

end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct LighterController

    battery_ok::Bool
    safety_closed::Bool
    gas_detected::Bool

    switch::BurnSwitch

    burning::Bool
    elapsed_ms::UInt32

end


function LighterController()

    LighterController(

        true,
        true,
        false,

        BurnSwitch(),

        false,
        UInt32(0)

    )

end


# ============================================================
# SAFETY
# ============================================================

function safe(
    lighter::LighterController
)

    lighter.battery_ok &&
    lighter.safety_closed &&
    !lighter.gas_detected

end


# ============================================================
# START BURN
# ============================================================

function start_burn!(
    lighter::LighterController
)

    if !safe(lighter)

        return false

    end

    lighter.burning = true
    lighter.elapsed_ms = UInt32(0)

    return true

end


# ============================================================
# CONTROL LOOP
# ============================================================

function update!(
    lighter::LighterController,
    dt_ms::Integer
)

    # Safety always dominates the burn switch.

    if !safe(lighter)

        lighter.burning = false
        lighter.elapsed_ms = UInt32(0)

        return :locked

    end


    if !lighter.burning

        return :idle

    end


    lighter.elapsed_ms +=
        UInt32(max(dt_ms, 0))


    selected =
        selected_profile(lighter.switch)


    # Automatically stop at selected duration.

    if lighter.elapsed_ms >=
       selected.duration_ms

        lighter.burning = false

        lighter.elapsed_ms = UInt32(0)

        return :complete

    end


    return :burning

end


# ============================================================
# SWITCH DISPLAY
# ============================================================

function switch_position(
    switch::BurnSwitch
)

    switch.selected == SHORT  && return 1
    switch.selected == MEDIUM && return 2
    switch.selected == LONG   && return 3

    error("Invalid switch position")

end


# ============================================================
# STATUS
# ============================================================

function status(
    lighter::LighterController
)

    selected =
        selected_profile(
            lighter.switch
        )


    println(
        "BURN SWITCH : ",
        selected.amount
    )

    println(
        "DURATION    : ",
        selected.duration_ms,
        " ms"
    )

    println(
        "POSITION    : ",
        switch_position(
            lighter.switch
        )
    )

    println(
        "BURNING     : ",
        lighter.burning
    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    lighter =
        LighterController()


    # Physical selector moved to MEDIUM.

    set_burn!(
        lighter.switch,
        MEDIUM
    )


    status(lighter)


    println()

    println(
        "START: ",
        start_burn!(lighter)
    )


    println(
        "TICK: ",
        update!(lighter, 250)
    )


    println(
        "TICK: ",
        update!(lighter, 250)
    )


    println(
        "TICK: ",
        update!(lighter, 500)
    )


    println()

    status(lighter)

end


end # module


# ============================================================
# RUN
# ============================================================

using .HydrogenLighterOS

HydrogenLighterOS.demo()

