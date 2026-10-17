# -------- BUILD STAGE --------
    FROM node:22-alpine AS builder

    WORKDIR /app
    
    COPY package*.json ./
    RUN npm ci
    
    COPY . .
    
    ARG VITE_API_URL
    ENV VITE_API_URL=${VITE_API_URL}

    # CloudWatch RUM (src/rum.ts) — optional; RUM is skipped when unset
    ARG VITE_RUM_APP_ID
    ARG VITE_RUM_IDENTITY_POOL_ID
    ARG VITE_AWS_REGION
    ENV VITE_RUM_APP_ID=${VITE_RUM_APP_ID} \
        VITE_RUM_IDENTITY_POOL_ID=${VITE_RUM_IDENTITY_POOL_ID} \
        VITE_AWS_REGION=${VITE_AWS_REGION}
    
    RUN npm run build
    
    
    # -------- PRODUCTION STAGE --------
    FROM nginx:1.27-alpine3.21
    
    # Remove default config if needed
    # RUN rm /etc/nginx/conf.d/default.conf
    
    # Fix permissions for non-root execution
    RUN chown -R nginx:nginx /usr/share/nginx/html \
        && chown -R nginx:nginx /var/cache/nginx \
        && chown -R nginx:nginx /var/log/nginx \
        && chown -R nginx:nginx /etc/nginx/conf.d \
        && touch /var/run/nginx.pid \
        && chown nginx:nginx /var/run/nginx.pid
    
    COPY --from=builder /app/dist /usr/share/nginx/html
    COPY nginx.conf /etc/nginx/conf.d/default.conf
    
    # 🔥 IMPORTANT: use non-privileged port
    EXPOSE 8080
    
    # Switch to non-root user
    USER nginx
    
    CMD ["nginx", "-g", "daemon off;"]