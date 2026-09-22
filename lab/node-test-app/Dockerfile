FROM node:20-alpine
WORKDIR /app
COPY ./package*.json ./
RUN npm install npm install express axios ejs 
COPY . .
EXPOSE 5000

COPY package*.json ./

CMD [ "npm" , "start" ]
