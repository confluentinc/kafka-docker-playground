FROM --platform=linux/amd64 node:20
WORKDIR /app
COPY package*.json ./
RUN OPENSSL_ia32cap=0x0 npm install
COPY . .
EXPOSE 9006
CMD [ "node", "server.js" ]