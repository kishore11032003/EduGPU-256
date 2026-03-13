# EduGPU-256

EduGPU-256 is a simplified GPU architecture simulator designed to demonstrate how modern GPUs execute massively parallel workloads using the SIMT (Single Instruction Multiple Threads) execution model.

The architecture simulates a 256-core GPU built using SystemVerilog and executed through Verilator-based hardware simulation. The project explores key GPU microarchitecture components such as warp scheduling, instruction pipelines, execution units, and memory subsystems.

--------------------------------------------------

Architecture Overview

EduGPU-256 implements a simplified GPU microarchitecture consisting of several core components that enable parallel execution.

The architecture includes:

• Instruction Fetch Unit  
• Instruction Decode Pipeline  
• Warp Scheduler  
• Register File  
• Integer ALU Execution Units  
• Floating Point Execution Units  
• Shared Memory Subsystem  
• VRAM Memory Controller  
• Streaming Multiprocessor Architecture  

These components collectively simulate GPU-style parallel execution where multiple threads execute the same instruction simultaneously.

--------------------------------------------------

SIMT Execution Model

EduGPU-256 follows the SIMT (Single Instruction Multiple Threads) model used in modern GPUs. In this model, a group of threads called a warp executes the same instruction simultaneously across multiple execution lanes.

This allows the GPU to achieve high parallelism and efficiently process large-scale computational workloads.

--------------------------------------------------

Technologies Used

SystemVerilog  
Verilator  
Linux Simulation Environment  
Digital Hardware Design  

--------------------------------------------------

Running the Simulation

To run the simulation using Verilator:

make
make tb-vram
make tb-tex
make sim-top

These commands compile and run the hardware simulation testbenches.

--------------------------------------------------

Project Goals

The primary goal of EduGPU-256 is to explore and demonstrate the internal design principles of GPU architectures, including:

• Parallel execution models  
• Warp scheduling  
• Execution pipelines  
• GPU memory hierarchy  
• Hardware simulation workflows  

This project serves as an educational exploration of GPU architecture and hardware system design.

--------------------------------------------------

Author

Kishore Kannan R S  
Bachelor of Engineering – Electronics and Communication Engineering  
Sri Sai Ram Institute of Technology
