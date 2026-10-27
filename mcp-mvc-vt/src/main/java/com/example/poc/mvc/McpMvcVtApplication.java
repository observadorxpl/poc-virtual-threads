package com.example.poc.mvc;

import java.time.Duration;

import org.springframework.ai.tool.ToolCallbackProvider;
import org.springframework.ai.tool.method.MethodToolCallbackProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@SpringBootApplication
public class McpMvcVtApplication {

    public static void main(String[] args) {
        SpringApplication.run(McpMvcVtApplication.class, args);
    }

    /**
     * JDK HttpClient: blocking send() parks the virtual thread instead of pinning a platform thread,
     * and its HTTP/1.1 pool has no fixed connection cap.
     */
    @Bean
    RestClient backendRestClient(@Value("${backend.base-url}") String baseUrl,
                                 @Value("${backend.timeout:10s}") Duration timeout) {
        java.net.http.HttpClient httpClient = java.net.http.HttpClient.newBuilder()
                .version(java.net.http.HttpClient.Version.HTTP_1_1)
                .connectTimeout(Duration.ofSeconds(2))
                .build();
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
        requestFactory.setReadTimeout(timeout);
        return RestClient.builder()
                .baseUrl(baseUrl)
                .requestFactory(requestFactory)
                .build();
    }

    @Bean
    ToolCallbackProvider balanceTools(BalanceTool balanceTool) {
        return MethodToolCallbackProvider.builder().toolObjects(balanceTool).build();
    }
}
