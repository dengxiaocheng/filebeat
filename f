cat > ~/f << 'EOF' && chmod +x ~/f
#!/data/data/com.termux/files/usr/bin/bash
ssh root@139.159.147.96 -t "su - openclaw -c 'bash -lc \"cd /home/openclaw/filebeat && claude --resume\"'"
EOF
