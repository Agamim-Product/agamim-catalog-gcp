# Image for the Cloud Run Job catalog-transform-<env>: the Dataform CLI plus this project, with core preinstalled.
FROM node:22.14.0-bookworm-slim

RUN npm install -g --no-audit --no-fund @dataform/cli@3.1.5 \
 && npm cache clean --force

WORKDIR /app/dataform
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY workflow_settings.yaml ./
COPY definitions ./definitions
COPY includes ./includes
COPY run.sh /app/run.sh

# Fail the build if the project does not compile.
RUN dataform compile . > /dev/null

RUN chmod 0555 /app/run.sh && chown -R node:node /app/dataform
USER node
ENTRYPOINT ["/app/run.sh"]
