#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
    ListResourcesRequestSchema,
    ReadResourceRequestSchema,
    ErrorCode,
    McpError
} from '@modelcontextprotocol/sdk/types.js';
import path from 'path';
import { promises as fs } from 'fs';
import axios from 'axios';

const RES_CATALOG = [
    {
        uri: 'r://docs/R/introduction',
        name: 'R Documentation (Intro)',
        mimeType: 'text/markdown',
        description: 'Introductory R documentation for quick reference'
    },
    {
        uri: 'rstudio://docs/open_source/introduction',
        name: 'RStudio Open Source Documentation (Intro)',
        mimeType: 'text/markdown',
        description: 'Introductory RStudio Open Source documentation and links'
    }
];

class RPServer {
    private server: Server;

    constructor() {
        this.server = new Server(
            { name: 'context7-mcp', version: '0.1.0' },
            { capabilities: { resources: {}, tools: {} } }
        );

        // Register resources
        this.server.setRequestHandler(ListResourcesRequestSchema, async () => ({
            resources: RES_CATALOG
        }));

        // ReadResource handler
        this.server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
            const uri = request.params.uri;

            if (uri === 'r://docs/R/introduction') {
                // Read the R docs file
                const docsPath = path.resolve(__dirname, '../../docs/r_docs.md');
                const content = await fs.readFile(docsPath, 'utf8');
                return {
                    contents: [
                        { uri, mimeType: 'text/markdown', text: content }
                    ]
                };
            } else if (uri === 'rstudio://docs/open_source/introduction') {
                // Read the RStudio OSS docs
                const docsPath = path.resolve(__dirname, '../../docs/rstudio_oss_intro.md');
                try {
                    const content = await fs.readFile(docsPath, 'utf8');
                    return { contents: [{ uri, mimeType: 'text/markdown', text: content }] };
                } catch {
                    // If file not found, return a friendly placeholder
                    return { contents: [{ uri, mimeType: 'text/markdown', text: '# RStudio Open Source Documentation\nNot yet added.' }] };
                }
            }

            throw new McpError(ErrorCode.InvalidRequest, `Unknown resource: ${uri}`);
        });

        // Start server (stdio transport)
        const transport = new StdioServerTransport();
        this.server.connect(transport);
    }
}

new RPServer();