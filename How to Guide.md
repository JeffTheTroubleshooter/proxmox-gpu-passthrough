# proxmox-gpu-passthrough

The Specs of my Proxmox Server 9.2.21
Running Linux Kernel 7.0.14.24 
Intel  i7-9700F 
Ram 8GB
GPU GeForce RTX 2060 SUPER

# Step 1
Download or git clone or copy the setup-gpu-passthrough.sh

# Step 2 
Make the script executable
chmod +x name of the script or setup-gpu-passthrough.sh

# Step 3
run the --check first to see if proxmox can see the GPU this is just a read only check  
./setup-gpu-passthrough.sh --check

# Step 4 
Run the script and click yes to all the stops to install the requirements for the GPU passthrough.
./setup-gpu-passthrough.sh
once you reach this step that is shown in the picture below of the script select the Virtual Machine ID you wanna add the GPU to you can also not add it to any Virtual machine and just have it enable and connect it to other virtual machine to your liking 
<img width="513" height="115" alt="image" src="https://github.com/user-attachments/assets/d24e6b21-1146-481a-9f0e-648d068f909b" />
# Step 5 
A completed configuration would look like this 

# Optional Steps 
if you wish to remove the GPU pass through configuration you can run the --remove command from the script  
./setup-gpu-passthrough.sh --remove
once the removal is completed it should look like this from the image example below 
<img width="1020" height="375" alt="image" src="https://github.com/user-attachments/assets/c5f80694-d3a9-4d06-b03e-9affe60819a9" />
This information could be different if you have a different GPU from mine but it should still display the same you should see the folloiing Default configuration 
nouveau → VGA
snd_hda_intel → audio
xhci_hcd → USB controller
nvidia-gpu → UCSI
if you see this configuration this is the default setting of your proxmox server 
