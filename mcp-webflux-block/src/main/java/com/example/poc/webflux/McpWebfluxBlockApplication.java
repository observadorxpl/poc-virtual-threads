package com.example.poc.webflux;

import java.time.Duration;

import org.springframework.ai.tool.ToolCallbackProvider;
import org.springframework.ai.tool.method.MethodToolCallbackProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.netty.http.client.HttpClient;
import reactor.netty.resources.ConnectionProvider;

@SpringBootApplication
public class McpWebfluxBlockApplication {

    public static void main(String[] args) {
        SpringApplication.run(McpWebfluxBlockApplication.class, args);
    }

    /**
     * Reactor Netty's default pool caps connections at max(cores, 8) * 2; it is raised so the
     * HTTP client is never the bottleneck and the comparison measures the execution model only.
     */
    @Bean
    WebClient backendWebClient(@Value("${backend.base-url}") String baseUrl,
                               @Value("${backend.max-connections:1000}") int maxConnections,
                               @Value("${backend.timeout:10s}") Duration timeout) {
        ConnectionProvider pool = ConnectionProvider.builder("backend")
                .maxConnections(maxConnections)
                .pendingAcquireMaxCount(-1)
                .pendingAcquireTimeout(timeout)
                .build();
        HttpClient httpClient = HttpClient.create(pool).responseTimeout(timeout);
        return WebClient.builder()
                .baseUrl(baseUrl)
                .clientConnector(new ReactorClientHttpConnector(httpClient))
                .build();
    }

    @Bean
    ToolCallbackProvider balanceTools(BalanceTool balanceTool) {
        return MethodToolCallbackProvider.builder().toolObjects(balanceTool).build();
    }
}
