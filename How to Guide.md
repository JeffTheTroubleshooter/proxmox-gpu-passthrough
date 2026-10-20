# proxmox-gpu-passthrough

The Specs of my Proxmox Server 9.2.21
Running Linux Kernel 7.0.14.24 
Intel  i7-9700F 
Ram 8GB
GPU NVIDIA 2060 SUPER

# Step 1
Download or git clone or copy the setup-gpu-passthrough.sh

# Step 2 
Make the script executable
chmod +x name of the script or setup-gpu-passthrough.sh

# Step 3
run the --check first to see if proxmox can see the GPU this is just a read only check  
./setup-gpu-passthrough.sh --check

# Step 4 
Run the script once you run it click yes to all
once you reach this step in the script select the Virtual Machine ID you wanna add the GPU to you can also not add it to any Virtual machine and just have it enable and connect it to other virtual machine to your liking 
<img width="513" height="115" alt="image" src="https://github.com/user-attachments/assets/d24e6b21-1146-481a-9f0e-648d068f909b" />
