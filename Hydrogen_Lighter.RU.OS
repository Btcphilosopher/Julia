# H2-LIGHTER.OS

## Minimal Embedded Rust Controller

```rust
#![no_std]

// ============================================================
// H2-LIGHTER.OS
//
// Minimal deterministic controller for a refillable
// hydrogen-assisted lighter.
//
// DESIGN:
//
//     SENSORS
//        |
//        v
//    SAFETY CHECK
//        |
//        v
//   STATE MACHINE
//        |
//        v
//    ACTUATORS
//
// The controller deliberately fails OFF.
//
// NOTE:
// Real hardware must provide independent mechanical/electrical
// protection for pressure, hydrogen flow, temperature,
// ignition and containment. Software must not be the only
// safety layer.
// ============================================================


#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Off,
    Ready,
    Igniting,
    Burning,
    Cooling,
    LowFuel,
    Fault,
}


// ============================================================
// SENSOR INPUTS
// ============================================================

#[derive(Clone, Copy, Debug)]
pub struct Sensors {
    pub hydrogen_available: bool,
    pub flame_detected: bool,
    pub ignition_feedback: bool,

    pub temperature_c: f32,
    pub pressure_ok: bool,

    pub cap_closed: bool,
    pub refill_detected: bool,
}


// ============================================================
// MACHINE LIMITS
// ============================================================

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub maximum_temperature_c: f32,
    pub maximum_run_time_s: f32,
}


impl Default for Limits {
    fn default() -> Self {
        Self {
            maximum_temperature_c: 70.0,
            maximum_run_time_s: 5.0,
        }
    }
}


// ============================================================
// ACTUATOR COMMANDS
// ============================================================

#[derive(Clone, Copy, Debug)]
pub struct Actuators {
    pub hydrogen_enabled: bool,
    pub ignition_enabled: bool,
}


impl Actuators {
    pub const fn off() -> Self {
        Self {
            hydrogen_enabled: false,
            ignition_enabled: false,
        }
    }

    pub fn shutdown(&mut self) {
        self.hydrogen_enabled = false;
        self.ignition_enabled = false;
    }
}


// ============================================================
// LIGHTER CONTROLLER
// ============================================================

pub struct Lighter {
    pub state: State,

    pub sensors: Sensors,
    pub limits: Limits,
    pub actuators: Actuators,

    pub run_time_s: f32,
}


impl Lighter {

    pub const fn new(
        sensors: Sensors,
        limits: Limits,
    ) -> Self {

        Self {
            state: State::Off,

            sensors,
            limits,

            actuators: Actuators::off(),

            run_time_s: 0.0,
        }
    }


    // ========================================================
    // POWER ON
    // ========================================================

    pub fn power_on(&mut self) {

        self.actuators.shutdown();

        self.run_time_s = 0.0;

        self.state = State::Ready;
    }


    // ========================================================
    // SAFETY CHECK
    // ========================================================

    fn safety_ok(&self) -> bool {

        let s = &self.sensors;

        if !s.pressure_ok {
            return false;
        }

        if !s.cap_closed {
            return false;
        }

        if !s.hydrogen_available {
            return false;
        }

        if s.temperature_c >=
           self.limits.maximum_temperature_c {
            return false;
        }

        true
    }


    // ========================================================
    // IGNITION REQUEST
    // ========================================================

    pub fn ignite(&mut self) -> bool {

        if self.state != State::Ready {
            return false;
        }

        if !self.safety_ok() {

            self.fault();

            return false;
        }

        self.run_time_s = 0.0;

        self.actuators.hydrogen_enabled = true;
        self.actuators.ignition_enabled = true;

        self.state = State::Igniting;

        true
    }


    // ========================================================
    // STOP
    // ========================================================

    pub fn stop(&mut self) {

        self.actuators.shutdown();

        self.state = State::Cooling;
    }


    // ========================================================
    // EMERGENCY STOP
    // ========================================================

    pub fn emergency_stop(&mut self) {

        self.actuators.shutdown();

        self.state = State::Fault;
    }


    // ========================================================
    // FAULT
    // ========================================================

    fn fault(&mut self) {

        self.actuators.shutdown();

        self.state = State::Fault;
    }


    // ========================================================
    // MAIN CONTROL TICK
    //
    // dt_s = elapsed time since previous tick.
    // ========================================================

    pub fn update(&mut self, dt_s: f32) {

        // ----------------------------------------------------
        // GLOBAL FAIL-SAFE CHECK
        // ----------------------------------------------------

        if !self.safety_ok() {

            self.fault();

            return;
        }


        // ----------------------------------------------------
        // STATE MACHINE
        // ----------------------------------------------------

        match self.state {

            State::Off => {
                self.actuators.shutdown();
            }


            State::Ready => {
                self.actuators.shutdown();
                self.run_time_s = 0.0;
            }


            State::Igniting => {

                self.run_time_s += dt_s;


                // Flame successfully established.
                if self.sensors.flame_detected {

                    self.actuators.ignition_enabled = false;

                    self.state = State::Burning;

                    return;
                }


                // Ignition timeout.
                if self.run_time_s >=
                   self.limits.maximum_run_time_s {

                    self.fault();

                    return;
                }
            }


            State::Burning => {

                self.run_time_s += dt_s;


                // Flame disappeared unexpectedly.
                if !self.sensors.flame_detected {

                    self.fault();

                    return;
                }


                // Absolute runtime limit.
                if self.run_time_s >=
                   self.limits.maximum_run_time_s {

                    self.stop();

                    return;
                }
            }


            State::Cooling => {

                self.actuators.shutdown();


                // Only return to READY once cool.
                if self.sensors.temperature_c < 35.0 {

                    if self.sensors.hydrogen_available {

                        self.state = State::Ready;

                    } else {

                        self.state = State::LowFuel;
                    }
                }
            }


            State::LowFuel => {

                self.actuators.shutdown();


                if self.sensors.refill_detected &&
                   self.sensors.hydrogen_available {

                    self.state = State::Ready;
                }
            }


            State::Fault => {

                // Fault state is deliberately latched.
                self.actuators.shutdown();
            }
        }
    }
}


// ============================================================
// HARDWARE ABSTRACTION
//
// The controller does not know whether the physical hardware
// is GPIO, CAN, I2C, SPI, ADC, etc.
//
// The MCU-specific implementation supplies these interfaces.
// ============================================================

pub trait SensorInterface {

    fn read_sensors(&mut self) -> Sensors;
}


pub trait ActuatorInterface {

    fn set_hydrogen(&mut self, enabled: bool);

    fn set_ignition(&mut self, enabled: bool);
}


// ============================================================
// CONTROLLER DRIVER
// ============================================================

pub struct Controller<S, A> {
    pub machine: Lighter,
    pub sensors: S,
    pub actuators: A,
}


impl<S, A> Controller<S, A>
where
    S: SensorInterface,
    A: ActuatorInterface,
{

    pub fn tick(&mut self, dt_s: f32) {

        // ----------------------------------------------------
        // READ HARDWARE
        // ----------------------------------------------------

        self.machine.sensors =
            self.sensors.read_sensors();


        // ----------------------------------------------------
        // RUN DETERMINISTIC CONTROL LOGIC
        // ----------------------------------------------------

        self.machine.update(dt_s);


        // ----------------------------------------------------
        // WRITE HARDWARE OUTPUTS
        // ----------------------------------------------------

        self.actuators.set_hydrogen(
            self.machine
                .actuators
                .hydrogen_enabled
        );


        self.actuators.set_ignition(
            self.machine
                .actuators
                .ignition_enabled
        );
    }
}


// ============================================================
// REFILL HANDLING
// ============================================================

impl Lighter {

    pub fn refill_complete(&mut self) {

        if self.sensors.refill_detected &&
           self.sensors.hydrogen_available {

            if self.state == State::LowFuel {

                self.state = State::Ready;

            }
        }
    }
}


// ============================================================
// TESTS
// ============================================================

#[cfg(test)]
mod tests {

    use super::*;


    fn normal_sensors() -> Sensors {

        Sensors {

            hydrogen_available: true,

            flame_detected: false,

            ignition_feedback: false,

            temperature_c: 22.0,

            pressure_ok: true,

            cap_closed: true,

            refill_detected: false,
        }
    }


    #[test]
    fn powers_on_safely() {

        let mut lighter =
            Lighter::new(
                normal_sensors(),
                Limits::default(),
            );


        lighter.power_on();


        assert_eq!(
            lighter.state,
            State::Ready
        );


        assert!(
            !lighter.actuators.hydrogen_enabled
        );


        assert!(
            !lighter.actuators.ignition_enabled
        );
    }


    #[test]
    fn ignition_requires_safe_conditions() {

        let mut sensors =
            normal_sensors();

        sensors.pressure_ok = false;


        let mut lighter =
            Lighter::new(
                sensors,
                Limits::default(),
            );


        lighter.power_on();


        assert!(
            !lighter.ignite()
        );


        assert_eq!(
            lighter.state,
            State::Fault
        );


        assert!(
            !lighter.actuators.hydrogen_enabled
        );
    }


    #[test]
    fn flame_establishes_burning_state() {

        let mut lighter =
            Lighter::new(
                normal_sensors(),
                Limits::default(),
            );


        lighter.power_on();

        assert!(
            lighter.ignite()
        );


        lighter.sensors.flame_detected = true;


        lighter.update(0.01);


        assert_eq!(
            lighter.state,
            State::Burning
        );


        assert!(
            lighter.actuators.hydrogen_enabled
        );


        assert!(
            !lighter.actuators.ignition_enabled
        );
    }


    #[test]
    fn flame_loss_causes_fault() {

        let mut lighter =
            Lighter::new(
                normal_sensors(),
                Limits::default(),
            );


        lighter.power_on();

        lighter.ignite();


        lighter.sensors.flame_detected = true;

        lighter.update(0.01);


        assert_eq!(
            lighter.state,
            State::Burning
        );


        lighter.sensors.flame_detected = false;

        lighter.update(0.01);


        assert_eq!(
            lighter.state,
            State::Fault
        );


        assert!(
            !lighter.actuators.hydrogen_enabled
        );
    }


    #[test]
    fn temperature_fault_shuts_everything_down() {

        let mut lighter =
            Lighter::new(
                normal_sensors(),
                Limits::default(),
            );


        lighter.power_on();

        lighter.ignite();


        lighter.sensors.flame_detected = true;

        lighter.update(0.01);


        lighter.sensors.temperature_c = 80.0;


        lighter.update(0.01);


        assert_eq!(
            lighter.state,
            State::Fault
        );


        assert!(
            !lighter.actuators.hydrogen_enabled
        );


        assert!(
            !lighter.actuators.ignition_enabled
        );
    }


    #[test]
    fn emergency_stop_is_immediate() {

        let mut lighter =
            Lighter::new(
                normal_sensors(),
                Limits::default(),
            );


        lighter.power_on();

        lighter.ignite();


        lighter.emergency_stop();


        assert_eq!(
            lighter.state,
            State::Fault
        );


        assert!(
            !lighter.actuators.hydrogen_enabled
        );


        assert!(
            !lighter.actuators.ignition_enabled
        );
    }
}
```

## Architecture

```text
                    H2-LIGHTER.OS
                          │
             ┌────────────┴────────────┐
             │                         │
        SENSOR INPUTS             USER INPUT
             │                         │
       ┌─────┼─────┐                   │
       │     │     │                   │
    Flame  Temp  Pressure               │
       │     │     │                   │
       └─────┼─────┘                   │
             │                         │
             ▼                         ▼
       ┌─────────────────────────────────┐
       │       SAFETY STATE MACHINE      │
       │                                 │
       │ OFF                             │
       │ READY                           │
       │ IGNITING                        │
       │ BURNING                         │
       │ COOLING                         │
       │ LOW_FUEL                        │
       │ FAULT                           │
       └──────────────┬──────────────────┘
                      │
                      ▼
               ACTUATOR COMMANDS
                      │
                ┌─────┴─────┐
                ▼           ▼
           H2 ENABLE     IGNITION
```

### Rust's role

The core remains deliberately tiny:

* **No heap allocation**
* **No dynamic strings**
* **No network dependency**
* **No AI**
* **No cloud dependency**
* **Explicit finite state machine**
* **Deterministic control loop**
* **Fail-closed actuator behaviour**
* **Unit tests for critical transitions**
* **Hardware abstraction traits**, allowing the same controller to be tested on a PC and later connected to an MCU

For an actual commercial device, I'd put the Rust controller behind a separate **hardware safety layer** rather than allowing software alone to determine hydrogen flow. The next step would be turning this into a proper embedded Rust project with an MCU HAL, watchdog, non-volatile usage counter, battery management, fault/event log and a tiny companion charging/refill state machine.

