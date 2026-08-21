FROM node:22-bookworm-slim

RUN npm install --global opencode-ai \
    && opencode --version

WORKDIR /workspace
EXPOSE 4096

HEALTHCHECK --interval=5s --timeout=3s --retries=12 \
  CMD node -e "fetch('http://127.0.0.1:4096/global/health').then(r=>{if(!r.ok)process.exit(1);return r.json()}).then(j=>{if(j.healthy!==true)process.exit(1)}).catch(()=>process.exit(1))"

ENTRYPOINT ["opencode"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "4096"]
