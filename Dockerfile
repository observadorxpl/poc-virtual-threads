# syntax=docker/dockerfile:1
# Shared multi-stage build. Usage: --build-arg MODULE=mcp-webflux-block | mcp-mvc-vt
FROM maven:3.9-eclipse-temurin-21 AS build
ARG MODULE
WORKDIR /src
COPY pom.xml .
COPY mcp-webflux-block/pom.xml mcp-webflux-block/
COPY mcp-mvc-vt/pom.xml mcp-mvc-vt/
RUN --mount=type=cache,target=/root/.m2 mvn -B -q -pl ${MODULE} -am dependency:go-offline
COPY mcp-webflux-block/src mcp-webflux-block/src
COPY mcp-mvc-vt/src mcp-mvc-vt/src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q -pl ${MODULE} -am package -DskipTests \
    && cp ${MODULE}/target/app.jar /app.jar

FROM eclipse-temurin:21-jre
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /app.jar /app/app.jar
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+UseG1GC"
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
