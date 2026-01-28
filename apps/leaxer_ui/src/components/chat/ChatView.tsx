import { memo, useRef, useEffect, useCallback, useState } from 'react';
import { ArrowDown } from 'lucide-react';
import { useChatStore } from '@/stores/chatStore';
import { useChatWebSocket } from '@/hooks/useChatWebSocket';
import { ChatMessage } from './ChatMessage';
import { ChatInput } from './ChatInput';
import { ChatWelcome } from './ChatWelcome';
import { ChatSidebar } from './ChatSidebar';
import { LlmServerControls } from './LlmServerControls';
import { ServerStarter } from './ServerStarter';
import { playStartSound, playReturnSound } from '@/lib/sounds';
import { notify } from '@/lib/notify';
import type { ChatCompletionMessage, ChatAttachment, ChatMessage as ChatMessageType } from '@/types/chat';

// System prompts
const BASE_SYSTEM_PROMPT = `You are a helpful assistant. Answer questions directly and concisely.`;

const THINKING_SYSTEM_PROMPT = `You are a helpful assistant that shows your reasoning process.

You MUST wrap your thinking in <think></think> tags before giving your response:

<think>
[Your step-by-step reasoning here]
</think>

[Your final response here]`;


export const ChatView = memo(() => {
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const currentMessageIdRef = useRef<string | null>(null);
  const artifactMessageIdRef = useRef<string | null>(null); // Track which message has the artifact
  const hasInitialScrolled = useRef<string | null>(null);
  const thinkingPhaseRef = useRef<{
    isThinking: boolean;
    thinkingContent: string;
    userMessage: string;
    sessionId: string;
    responseMessageId: string | null;
  } | null>(null);
  const onThinkingCompleteRef = useRef<(() => void) | null>(null);
  const [showScrollButton, setShowScrollButton] = useState(false);
  const [hasMounted, setHasMounted] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [editingMessage, setEditingMessage] = useState<{ id: string; content: string } | null>(null);
  const shouldAutoScrollRef = useRef(true);
  const [isStartingServer, setIsStartingServer] = useState(false);

  // Entrance animation on mount
  useEffect(() => {
    const timer = setTimeout(() => setHasMounted(true), 50);
    return () => clearTimeout(timer);
  }, []);

  // Chat store state - use selectors that subscribe to actual data
  const activeSessionId = useChatStore((s) => s.activeSessionId);
  const sessions = useChatStore((s) => s.sessions);
  const isGenerating = useChatStore((s) => s.isGenerating);
  const selectedModel = useChatStore((s) => s.selectedModel);
  const createSession = useChatStore((s) => s.createSession);
  const addMessage = useChatStore((s) => s.addMessage);
  const updateMessage = useChatStore((s) => s.updateMessage);
  const appendToMessage = useChatStore((s) => s.appendToMessage);
  const setMessageStreaming = useChatStore((s) => s.setMessageStreaming);
  const setMessageFollowUps = useChatStore((s) => s.setMessageFollowUps);
  const setMessageReferences = useChatStore((s) => s.setMessageReferences);
  const setIsGenerating = useChatStore((s) => s.setIsGenerating);
  const setModelStatus = useChatStore((s) => s.setModelStatus);
  const setSelectedModel = useChatStore((s) => s.setSelectedModel);
  const loadSessionsFromBackend = useChatStore((s) => s.loadSessionsFromBackend);
  const saveSessionToBackend = useChatStore((s) => s.saveSessionToBackend);
  const deleteMessage = useChatStore((s) => s.deleteMessage);
  const setMessageHiding = useChatStore((s) => s.setMessageHiding);
  const thinkingEnabled = useChatStore((s) => s.thinkingEnabled);
  const internetEnabled = useChatStore((s) => s.internetEnabled);
  const artifactEnabled = useChatStore((s) => s.artifactEnabled);
  const searchProvider = useChatStore((s) => s.searchProvider);
  const searchMaxResults = useChatStore((s) => s.searchMaxResults);
  const setChatStatus = useChatStore((s) => s.setChatStatus);
  const setMessageArtifact = useChatStore((s) => s.setMessageArtifact);
  const updateMessageArtifact = useChatStore((s) => s.updateMessageArtifact);
  const appendToArtifact = useChatStore((s) => s.appendToArtifact);
  const moveArtifactToMessage = useChatStore((s) => s.moveArtifactToMessage);
  const renameSession = useChatStore((s) => s.renameSession);
  const llmServerStatus = useChatStore((s) => s.llmServerStatus);
  const setLlmServerStatus = useChatStore((s) => s.setLlmServerStatus);
  const addLlmServerLog = useChatStore((s) => s.addLlmServerLog);
  const clearLlmServerLogs = useChatStore((s) => s.clearLlmServerLogs);

  // Get active session - derive from subscribed state
  const activeSession = activeSessionId
    ? sessions.find((s) => s.id === activeSessionId)
    : null;
  const messages = activeSession?.messages || [];

  // Load sessions on mount
  useEffect(() => {
    loadSessionsFromBackend();
  }, [loadSessionsFromBackend]);

  // Generate follow-up suggestions using the LLM
  const generateFollowUps = useCallback(
    async (sessionId: string, messageId: string, assistantResponse: string) => {
      const followUpPrompt = `You are helping a user who just received this AI response. Suggest exactly 3 short follow-up questions (max 6 words each) that the USER might want to ask next to learn more or go deeper. Write from the user's perspective. Output ONLY the questions, one per line, no numbers or bullets.

Response: "${assistantResponse.slice(0, 400)}"`;

      try {
        // Call llama-server directly (it runs on port 8080)
        const response = await fetch('http://127.0.0.1:8080/v1/chat/completions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            messages: [{ role: 'user', content: followUpPrompt }],
            max_tokens: 60,
            temperature: 0.8,
            stream: false,
          }),
        });

        if (response.ok) {
          const data = await response.json();
          const content = data.choices?.[0]?.message?.content || '';
          const followUps = content
            .split('\n')
            .map((line: string) => line.replace(/^[\d\-.)*]+\s*/, '').trim())
            .filter((line: string) => line.length > 0 && line.length < 50)
            .slice(0, 3);

          if (followUps.length > 0) {
            setMessageFollowUps(sessionId, messageId, followUps);
            // Save session to persist follow-ups
            saveSessionToBackend(sessionId);
          }
        }
      } catch {
        // Silently fail - follow-ups are optional
      }
    },
    [setMessageFollowUps, saveSessionToBackend]
  );

  // Generate a title for the chat session after first response
  const generateSessionTitle = useCallback(
    async (sessionId: string, userMessage: string, assistantResponse: string) => {
      const session = useChatStore.getState().sessions.find((s) => s.id === sessionId);
      // Only generate title if it's still "New Chat" and this is the first exchange
      if (!session || session.name !== 'New Chat' || session.messages.length > 2) {
        return;
      }

      const titlePrompt = `Generate a very short title (2-5 words max) for this chat conversation. Just output the title, nothing else.

User: "${userMessage.slice(0, 200)}"
Assistant: "${assistantResponse.slice(0, 300)}"`;

      try {
        const response = await fetch('http://127.0.0.1:8080/v1/chat/completions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            messages: [{ role: 'user', content: titlePrompt }],
            max_tokens: 20,
            temperature: 0.7,
            stream: false,
          }),
        });

        if (response.ok) {
          const data = await response.json();
          let title = data.choices?.[0]?.message?.content || '';
          // Clean up the title
          title = title
            .replace(/^["']|["']$/g, '') // Remove quotes
            .replace(/^Title:\s*/i, '') // Remove "Title:" prefix
            .trim();

          if (title && title.length > 0 && title.length < 50) {
            renameSession(sessionId, title);
          }
        }
      } catch {
        // Silently fail - title generation is optional
      }
    },
    [renameSession]
  );

  // WebSocket connection with callbacks
  const {
    connected: wsConnected,
    sendMessage,
    abortGeneration,
    loadModel,
    getLlmServerHealth,
    restartLlmServer,
    startLlmServer,
  } = useChatWebSocket({
    onModelStatus: (status) => {
      setModelStatus(status.status);
    },
    onStreamChunk: (chunk) => {
      if (currentMessageIdRef.current && activeSessionId && chunk.content) {
        // Guard against undefined/null content being appended
        appendToMessage(activeSessionId, currentMessageIdRef.current, chunk.content);
        // Also capture thinking content for two-pass approach
        if (thinkingPhaseRef.current?.isThinking) {
          thinkingPhaseRef.current.thinkingContent += chunk.content;
        }
      }
    },
    onGenerationComplete: (_data) => {
      const messageId = currentMessageIdRef.current;
      const sessionId = activeSessionId;

      // Check if this was a thinking phase completion
      if (thinkingPhaseRef.current?.isThinking && onThinkingCompleteRef.current) {
        thinkingPhaseRef.current.isThinking = false;
        if (messageId && sessionId) {
          setMessageStreaming(sessionId, messageId, false);
        }
        // Trigger response phase
        const callback = onThinkingCompleteRef.current;
        onThinkingCompleteRef.current = null;
        callback();
        return;
      }

      if (messageId && sessionId) {
        setMessageStreaming(sessionId, messageId, false);

        // Save session after generation completes
        saveSessionToBackend(sessionId);

        // Generate follow-up suggestions (only for final response, not thinking)
        const session = useChatStore.getState().sessions.find((s) => s.id === sessionId);
        const message = session?.messages.find((m) => m.id === messageId);
        if (message?.content) {
          generateFollowUps(sessionId, messageId, message.content);

          // Generate title for new chats after first response
          const userMessages = session?.messages.filter((m) => m.role === 'user');
          if (userMessages && userMessages.length === 1) {
            generateSessionTitle(sessionId, userMessages[0].content, message.content);
          }
        }
      }
      currentMessageIdRef.current = null;
      artifactMessageIdRef.current = null;
      thinkingPhaseRef.current = null;
      setIsGenerating(false);
      setChatStatus('idle');
      playReturnSound();
    },
    onGenerationError: (error) => {
      console.error('Generation error:', error);

      // Parse error message for user-friendly notifications
      let errorMessage = error.error || 'An error occurred during generation';

      if (errorMessage.includes('exceed_context_size') || errorMessage.includes('exceeds the available context')) {
        // Extract token counts if available
        const match = errorMessage.match(/(\d+) tokens\).*?(\d+) tokens/);
        if (match) {
          errorMessage = `Message too large (${match[1]} tokens) for model context (${match[2]} tokens). Try a shorter message or smaller attachment.`;
        } else {
          errorMessage = 'Message exceeds model context size. Try a shorter message or smaller attachment.';
        }
      }

      notify.error(errorMessage);

      // Clean up the streaming message if there was one
      if (currentMessageIdRef.current && activeSessionId) {
        setMessageStreaming(activeSessionId, currentMessageIdRef.current, false);
      }
      currentMessageIdRef.current = null;
      setIsGenerating(false);
      setChatStatus('idle');
    },
    onToolStatus: (status) => {
      // Update chat status pill
      if (status.status === 'searching') {
        setChatStatus('searching', status.query);
      } else if (status.status === 'complete') {
        // After search completes, show 'thinking' if thinking is enabled, otherwise 'generating'
        const currentThinkingEnabled = useChatStore.getState().thinkingEnabled;
        setChatStatus(currentThinkingEnabled ? 'thinking' : 'generating');
      } else if (status.status === 'error') {
        setChatStatus('generating');
      }
      // Handle tool status updates
      if (currentMessageIdRef.current && activeSessionId) {
        if (status.status === 'searching') {
          // Strip out the tool call JSON from the message and replace with searching indicator
          const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
          const message = session?.messages.find((m) => m.id === currentMessageIdRef.current);
          if (message) {
            // Remove tool call JSON pattern from content
            const cleanedContent = message.content
              .replace(/\{[\s\S]*?"tool"[\s\S]*?"web_search"[\s\S]*?\}/g, '')
              .trim();
            updateMessage(activeSessionId, currentMessageIdRef.current, cleanedContent + '\n\n*Searching the web...*\n\n');
          }
        } else if (status.status === 'complete') {
          // Store references for display
          if (status.references && status.references.length > 0) {
            setMessageReferences(activeSessionId, currentMessageIdRef.current, status.references);
          }
          // Remove the "Searching..." text since we'll stream the answer
          const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
          const message = session?.messages.find((m) => m.id === currentMessageIdRef.current);
          if (message) {
            const cleanedContent = message.content.replace(/\n\n\*Searching the web\.\.\.\*\n\n$/, '');
            updateMessage(activeSessionId, currentMessageIdRef.current, cleanedContent);
          }
        } else if (status.status === 'error') {
          appendToMessage(activeSessionId, currentMessageIdRef.current, `\n\n*Search failed: ${status.error}*`);
        }
      }
    },
    onArtifactStatus: (status) => {
      // Handle artifact generation status
      if (activeSessionId) {
        if (status.status === 'pending' || status.status === 'generating') {
          setChatStatus('creating');

          // Check if there's an existing artifact in the session
          const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
          const existingArtifactMessage = session?.messages.find((m) => m.artifact);

          if (existingArtifactMessage && currentMessageIdRef.current) {
            // Check if artifact is already on the current message (avoid moving to same message)
            if (existingArtifactMessage.id === currentMessageIdRef.current) {
              // Artifact already on current message, just update status
              artifactMessageIdRef.current = currentMessageIdRef.current;
              updateMessageArtifact(activeSessionId, currentMessageIdRef.current, {
                status: status.status,
              });
            } else {
              // Move artifact to current message (creates new version)
              artifactMessageIdRef.current = currentMessageIdRef.current;
              moveArtifactToMessage(activeSessionId, existingArtifactMessage.id, currentMessageIdRef.current);
            }
          } else if (currentMessageIdRef.current) {
            // Create new artifact on current message
            artifactMessageIdRef.current = currentMessageIdRef.current;
            setMessageArtifact(activeSessionId, currentMessageIdRef.current, {
              id: `artifact_${Date.now()}`,
              title: 'Research Document',
              content: '',
              created_at: Date.now(),
              status: status.status,
              versions: [],
              currentVersion: 1,
            });
          }
        } else if (status.status === 'complete' && status.title && status.content) {
          // Update artifact with completed content
          const targetMessageId = artifactMessageIdRef.current || currentMessageIdRef.current;
          if (targetMessageId) {
            // Get the message's references (from web search) to include in artifact
            const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
            const targetMessage = session?.messages.find((m) => m.id === targetMessageId);
            const newSources = targetMessage?.references || [];

            // Merge with existing artifact sources (for refinement), avoiding duplicates by URL
            const existingSources = targetMessage?.artifact?.sources || [];
            const existingUrls = new Set(existingSources.map(s => s.url));
            const mergedSources = [
              ...existingSources,
              ...newSources.filter(s => !existingUrls.has(s.url))
            ];

            updateMessageArtifact(activeSessionId, targetMessageId, {
              title: status.title,
              content: status.content,
              status: 'complete',
              sources: mergedSources,
            });
          }
          setChatStatus('idle');
          // Save session to persist artifact
          saveSessionToBackend(activeSessionId);
        } else if (status.status === 'error') {
          const targetMessageId = artifactMessageIdRef.current || currentMessageIdRef.current;
          if (targetMessageId) {
            updateMessageArtifact(activeSessionId, targetMessageId, {
              status: 'error',
            });
          }
          setChatStatus('idle');
        }
      }
    },
    onArtifactChunk: (chunk) => {
      // Append streamed content to artifact
      const targetMessageId = artifactMessageIdRef.current || currentMessageIdRef.current;
      console.log('[ChatView] Received artifact chunk:', chunk.content.length, 'chars, messageId:', targetMessageId);
      if (targetMessageId && activeSessionId) {
        appendToArtifact(activeSessionId, targetMessageId, chunk.content);
      }
    },
    onLlmServerStatus: (status) => {
      // Update LLM server status in store
      setLlmServerStatus(status.status, status.error);
      // Also update model status for consistency
      if (status.status === 'ready') {
        setModelStatus('ready');
      } else if (status.status === 'loading') {
        setModelStatus('loading');
      }
    },
    onLlmServerLog: (log) => {
      // Add startup log to store
      addLlmServerLog(log.line, log.timestamp);
    },
  });

  // Fetch initial LLM server health status when WebSocket connects
  useEffect(() => {
    if (wsConnected) {
      getLlmServerHealth()
        .then((health) => {
          setLlmServerStatus(health.status as 'idle' | 'loading' | 'ready' | 'error', health.error);
        })
        .catch((err) => {
          console.error('Failed to get LLM server health:', err);
          // Assume idle if we can't get status
          setLlmServerStatus('idle');
        });
    }
  }, [wsConnected, getLlmServerHealth, setLlmServerStatus]);

  // Check if scrolled to bottom
  const checkIfAtBottom = useCallback(() => {
    const container = scrollContainerRef.current;
    if (!container) return true;
    const threshold = 100; // pixels from bottom
    return container.scrollHeight - container.scrollTop - container.clientHeight < threshold;
  }, []);

  // Handle scroll events
  const handleScroll = useCallback(() => {
    const atBottom = checkIfAtBottom();

    // Update auto-scroll preference based on user scroll position
    shouldAutoScrollRef.current = atBottom;

    // Show scroll button when not at bottom (including during generation)
    setShowScrollButton(!atBottom);
  }, [checkIfAtBottom]);

  // Scroll to bottom function
  const scrollToBottom = useCallback((resumeAutoScroll = false) => {
    if (resumeAutoScroll) {
      shouldAutoScrollRef.current = true;
    }
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, []);

  // Scroll to bottom on initial load or when switching sessions
  useEffect(() => {
    if (activeSessionId && messages.length > 0 && hasInitialScrolled.current !== activeSessionId) {
      // Use instant scroll on initial load
      messagesEndRef.current?.scrollIntoView({ behavior: 'auto' });
      hasInitialScrolled.current = activeSessionId;
    }
  }, [activeSessionId, messages.length]);

  // Auto-scroll during generation only if user hasn't scrolled up
  useEffect(() => {
    if (isGenerating && shouldAutoScrollRef.current) {
      scrollToBottom();
    }
  }, [messages, isGenerating, scrollToBottom]);

  // Auto-scroll when new message is added (user sends a message)
  // Reset auto-scroll to true so user can follow their message and response
  useEffect(() => {
    shouldAutoScrollRef.current = true;
    scrollToBottom();
  }, [messages.length, scrollToBottom]);

  // Helper to build API messages from session with context truncation
  const buildApiMessages = useCallback((session: { messages: Array<{ role: string; content: string; attachments?: ChatAttachment[] }> }, systemPrompt: string, maxContextChars = 8000) => {
    // Estimate: ~4 chars per token, leave room for response (~1000 tokens = 4000 chars)
    // Default maxContextChars = 8000 allows ~2000 tokens for prompt

    const systemMessage: ChatCompletionMessage = { role: 'system', content: systemPrompt };
    const systemChars = systemPrompt.length;

    // Process messages, merging consecutive same-role messages
    const processedMessages: ChatCompletionMessage[] = [];
    let lastRole: string | null = null;

    for (const m of session.messages) {
      // Skip empty assistant messages
      if (m.role === 'assistant' && m.content.trim() === '') continue;
      // Strip thinking tags from content for context (keep response only)
      let content = m.content;
      if (m.role === 'assistant') {
        content = content.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
        if (!content) continue;
      }

      // Prepend text file contents for user messages with attachments
      if (m.role === 'user') {
        console.log('[buildApiMessages] User message attachments:', m.attachments?.length ?? 0);
        if (m.attachments && m.attachments.length > 0) {
          m.attachments.forEach(a => console.log('  -', a.name, 'textContent:', a.textContent?.length ?? 'NONE'));
          const textAttachments = m.attachments.filter(a => !a.requiresVision && a.textContent);
          console.log('[buildApiMessages] Text attachments after filter:', textAttachments.length);
          if (textAttachments.length > 0) {
            const attachmentText = textAttachments
              .map(a => `<file name="${a.name}">\n${a.textContent}\n</file>`)
              .join('\n\n');
            content = `${attachmentText}\n\n${content}`;
            console.log('[buildApiMessages] Content now includes file, total length:', content.length);
          }
        }
      }

      if (m.role === lastRole && processedMessages.length > 0) {
        const lastMsg = processedMessages[processedMessages.length - 1];
        lastMsg.content += '\n' + content;
      } else {
        processedMessages.push({ role: m.role as 'user' | 'assistant' | 'system', content });
        lastRole = m.role;
      }
    }

    // Truncate from the beginning, keeping most recent messages
    const availableChars = maxContextChars - systemChars;
    let includedMessages: ChatCompletionMessage[] = [];
    let totalChars = 0;

    // Work backwards from most recent
    for (let i = processedMessages.length - 1; i >= 0; i--) {
      const msg = processedMessages[i];
      const msgChars = msg.content.length;

      // Always include the most recent message (even if it exceeds limit)
      // This ensures file attachments are not dropped
      if (i === processedMessages.length - 1) {
        includedMessages.unshift(msg);
        totalChars += msgChars;
        continue;
      }

      if (totalChars + msgChars <= availableChars) {
        includedMessages.unshift(msg);
        totalChars += msgChars;
      } else {
        // Can't fit more messages
        break;
      }
    }

    // Ensure first message after system is a user message (required by most LLMs)
    while (includedMessages.length > 0 && includedMessages[0].role === 'assistant') {
      includedMessages = includedMessages.slice(1);
    }

    // Ensure proper role alternation (merge any consecutive same-role after truncation)
    const finalMessages: ChatCompletionMessage[] = [];
    for (const msg of includedMessages) {
      if (finalMessages.length > 0 && finalMessages[finalMessages.length - 1].role === msg.role) {
        finalMessages[finalMessages.length - 1].content += '\n' + msg.content;
      } else {
        finalMessages.push({ ...msg });
      }
    }

    return [systemMessage, ...finalMessages];
  }, []);

  // Handle sending a message
  const handleSend = useCallback(
    async (content: string, attachments?: ChatAttachment[]) => {
      if (!selectedModel) {
        console.error('No model selected');
        return;
      }

      // Create a new session if none exists
      let sessionId = activeSessionId;
      if (!sessionId) {
        sessionId = createSession();
      }

      // Handle edit: delete original message and response, then add edited message
      if (editingMessage) {
        const session = useChatStore.getState().sessions.find((s) => s.id === sessionId);
        if (session) {
          const editIndex = session.messages.findIndex((m) => m.id === editingMessage.id);
          if (editIndex !== -1) {
            // Get attachments from the original message
            const originalAttachments = session.messages[editIndex].attachments;
            // Delete all messages from the edited message onwards
            const messagesToDelete = session.messages.slice(editIndex);
            for (let i = messagesToDelete.length - 1; i >= 0; i--) {
              deleteMessage(sessionId, messagesToDelete[i].id);
            }
            // Use original attachments if no new ones provided
            attachments = attachments || originalAttachments;
          }
        }
        setEditingMessage(null);
      }

      // Add user message to session (attachments stored for API context building)
      addMessage(sessionId, 'user', content, undefined, attachments);

      const session = useChatStore.getState().sessions.find((s) => s.id === sessionId);
      if (!session) return;

      setIsGenerating(true);
      playStartSound();

      // Determine the mode based on enabled features
      // Priority: Internet search first, then thinking
      const useInternetFirst = internetEnabled;
      const useThinkingOnly = thinkingEnabled && !internetEnabled;

      // Set initial status - internet mode will update to 'searching' if tool call detected
      if (useInternetFirst) {
        setChatStatus('generating');
      } else if (thinkingEnabled) {
        setChatStatus('thinking');
      } else {
        setChatStatus('generating');
      }

      // INTERNET MODE (with optional thinking) - search first, then respond
      if (useInternetFirst) {

        // Use base prompt - backend will handle tool prompt and thinking instructions
        const apiMessages = buildApiMessages(session, BASE_SYSTEM_PROMPT);

        // Add assistant message placeholder for streaming
        const assistantMessageId = addMessage(sessionId, 'assistant', '', selectedModel);
        currentMessageIdRef.current = assistantMessageId;

        // Find existing artifact for refinement
        const existingArtifactMessage = session.messages.find((m) => m.artifact);
        const existingArtifactContent = existingArtifactMessage?.artifact?.content;

        try {
          // Pass thinkingEnabled so backend can include thinking instructions after search
          await sendMessage(apiMessages, selectedModel, session.settings, true, searchProvider, searchMaxResults, thinkingEnabled, artifactEnabled, existingArtifactContent);
        } catch (err) {
          console.error('Failed to send message:', err);
          setIsGenerating(false);
          setChatStatus('idle');
          if (currentMessageIdRef.current && sessionId) {
            appendToMessage(
              sessionId,
              currentMessageIdRef.current,
              `**Error:** ${err instanceof Error ? err.message : 'Failed to send message'}`
            );
            setMessageStreaming(sessionId, currentMessageIdRef.current, false);
          }
          currentMessageIdRef.current = null;
        }
        return;
      }

      // TWO-PASS THINKING MODE (no internet)
      if (useThinkingOnly) {

        // Build conversation history (excluding the thinking/response we're about to generate)
        const historyMessages = buildApiMessages(session, BASE_SYSTEM_PROMPT);
        const historyWithoutSystem = historyMessages.slice(1);

        // Phase 1: Generate thinking - include conversation history
        // Merge thinking instruction with last user message to avoid consecutive user messages
        const thinkingMessages: ChatCompletionMessage[] = [
          { role: 'system', content: 'You are a helpful assistant. Think carefully and show your reasoning process. Consider the conversation context when analyzing.' },
        ];

        // Add history, but merge thinking instruction into the last user message
        if (historyWithoutSystem.length === 0) {
          // Fallback: just add the user's content with thinking instruction
          thinkingMessages.push({
            role: 'user',
            content: `${content}\n\nThink step by step about how to answer this. Analyze the problem, consider different aspects, and outline your reasoning process.`,
          });
        } else {
          for (let i = 0; i < historyWithoutSystem.length; i++) {
            const msg = historyWithoutSystem[i];
            if (i === historyWithoutSystem.length - 1 && msg.role === 'user') {
              // Merge thinking instruction with last user message
              thinkingMessages.push({
                role: 'user',
                content: `${msg.content}\n\nThink step by step about how to answer this. Analyze the problem, consider different aspects, and outline your reasoning process.`,
              });
            } else {
              thinkingMessages.push(msg);
            }
          }
          // If last message wasn't user, add fallback user message
          if (thinkingMessages[thinkingMessages.length - 1]?.role !== 'user') {
            thinkingMessages.push({
              role: 'user',
              content: `Think step by step about how to answer: ${content}`,
            });
          }
        }

        // Add thinking message placeholder (will contain <think> wrapper)
        const thinkingMessageId = addMessage(sessionId, 'assistant', '<think>', selectedModel);
        currentMessageIdRef.current = thinkingMessageId;

        // Set up thinking phase tracking
        thinkingPhaseRef.current = {
          isThinking: true,
          thinkingContent: '',
          userMessage: content,
          sessionId: sessionId,
          responseMessageId: null,
        };

        // Set up callback for when thinking completes
        onThinkingCompleteRef.current = async () => {
          setChatStatus('generating');
          const thinkingContent = thinkingPhaseRef.current?.thinkingContent || '';
          const currentSession = useChatStore.getState().sessions.find((s) => s.id === sessionId);

          // Close the thinking tag in the thinking message
          if (thinkingMessageId) {
            appendToMessage(sessionId, thinkingMessageId, '</think>\n\n');
          }

          // Phase 2: Generate response - include conversation history + thinking context
          const responseMessages: ChatCompletionMessage[] = [
            { role: 'system', content: BASE_SYSTEM_PROMPT },
          ];

          // Add history, but merge response instruction into the last user message
          if (historyWithoutSystem.length === 0) {
            // Fallback: just add the response instruction
            responseMessages.push({
              role: 'user',
              content: `Based on this reasoning:\n\n${thinkingContent}\n\nNow write a clear, well-structured response to: ${content}`,
            });
          } else {
            for (let i = 0; i < historyWithoutSystem.length; i++) {
              const msg = historyWithoutSystem[i];
              if (i === historyWithoutSystem.length - 1 && msg.role === 'user') {
                // Merge response instruction with last user message
                responseMessages.push({
                  role: 'user',
                  content: `${msg.content}\n\nBased on this reasoning:\n\n${thinkingContent}\n\nNow write a clear, well-structured response. Present your answer naturally - do not include labels like "Final Answer:" or mention that you did analysis.`,
                });
              } else {
                responseMessages.push(msg);
              }
            }
            // If last message wasn't user, add fallback user message
            if (responseMessages[responseMessages.length - 1]?.role !== 'user') {
              responseMessages.push({
                role: 'user',
                content: `Based on this reasoning:\n\n${thinkingContent}\n\nNow write a clear, well-structured response to: ${content}`,
              });
            }
          }

          // Continue in the same message after </think>
          currentMessageIdRef.current = thinkingMessageId;
          setMessageStreaming(sessionId, thinkingMessageId, true);

          // Find existing artifact for refinement
          const existingArtifactMsg = currentSession?.messages.find((m) => m.artifact);
          const existingArtifactContent = existingArtifactMsg?.artifact?.content;

          try {
            await sendMessage(responseMessages, selectedModel, currentSession?.settings || session.settings, false, searchProvider, searchMaxResults, false, artifactEnabled, existingArtifactContent);
          } catch (err) {
            console.error('Failed to send response:', err);
            setIsGenerating(false);
            setChatStatus('idle');
            thinkingPhaseRef.current = null;
          }
        };

        try {
          // Don't pass artifactEnabled to thinking phase - only to final response
          await sendMessage(thinkingMessages, selectedModel, session.settings, false, searchProvider, searchMaxResults, false, false);
        } catch (err) {
          console.error('Failed to send thinking:', err);
          setIsGenerating(false);
          setChatStatus('idle');
          thinkingPhaseRef.current = null;
          onThinkingCompleteRef.current = null;
          if (currentMessageIdRef.current && sessionId) {
            appendToMessage(sessionId, currentMessageIdRef.current, `\n\n**Error:** ${err instanceof Error ? err.message : 'Failed to generate thinking'}`);
            setMessageStreaming(sessionId, currentMessageIdRef.current, false);
          }
          currentMessageIdRef.current = null;
        }
        return;
      }

      // STANDARD MODE (no thinking)
      const apiMessages = buildApiMessages(session, BASE_SYSTEM_PROMPT);

      // Add assistant message placeholder for streaming
      const assistantMessageId = addMessage(sessionId, 'assistant', '', selectedModel);
      currentMessageIdRef.current = assistantMessageId;

      // Find existing artifact for refinement
      const existingArtifactMessage = session.messages.find((m) => m.artifact);
      const existingArtifactContent = existingArtifactMessage?.artifact?.content;

      try {
        await sendMessage(apiMessages, selectedModel, session.settings, internetEnabled, searchProvider, searchMaxResults, false, artifactEnabled, existingArtifactContent);
      } catch (err) {
        console.error('Failed to send message:', err);
        setIsGenerating(false);
        setChatStatus('idle');
        if (currentMessageIdRef.current && sessionId) {
          appendToMessage(
            sessionId,
            currentMessageIdRef.current,
            `**Error:** ${err instanceof Error ? err.message : 'Failed to send message'}`
          );
          setMessageStreaming(sessionId, currentMessageIdRef.current, false);
        }
        currentMessageIdRef.current = null;
      }
    },
    [
      activeSessionId,
      selectedModel,
      thinkingEnabled,
      internetEnabled,
      artifactEnabled,
      searchProvider,
      searchMaxResults,
      createSession,
      addMessage,
      deleteMessage,
      appendToMessage,
      setMessageStreaming,
      setIsGenerating,
      setChatStatus,
      sendMessage,
      buildApiMessages,
      editingMessage,
    ]
  );

  // Handle abort
  const handleAbort = useCallback(() => {
    abortGeneration();
    setIsGenerating(false);
    setChatStatus('idle');
    if (currentMessageIdRef.current && activeSessionId) {
      setMessageStreaming(activeSessionId, currentMessageIdRef.current, false);
    }
    currentMessageIdRef.current = null;
  }, [abortGeneration, activeSessionId, setIsGenerating, setMessageStreaming, setChatStatus]);

  // Handle regenerating a message
  const handleRegenerate = useCallback(
    async (messageId: string) => {
      if (!selectedModel || !activeSessionId || isGenerating) return;

      const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
      if (!session) return;

      // Find the message index
      const messageIndex = session.messages.findIndex((m) => m.id === messageId);
      if (messageIndex === -1) return;

      // Build messages up to (but not including) the message being regenerated
      const apiMessages: ChatCompletionMessage[] = [];

      // Add default system message
      apiMessages.push({
        role: 'system',
        content: thinkingEnabled ? THINKING_SYSTEM_PROMPT : BASE_SYSTEM_PROMPT,
      });

      // Process messages up to the one being regenerated
      let lastRole: string | null = 'system';
      for (let i = 0; i < messageIndex; i++) {
        const m = session.messages[i];

        // Skip empty assistant messages
        if (m.role === 'assistant' && m.content.trim() === '') {
          continue;
        }

        // Skip if same role as last
        if (m.role === lastRole) {
          if (m.role === 'user' && apiMessages.length > 0) {
            const lastMsg = apiMessages[apiMessages.length - 1];
            if (lastMsg.role === 'user') {
              lastMsg.content += '\n' + m.content;
              continue;
            }
          }
        }

        apiMessages.push({
          role: m.role,
          content: m.content,
        });
        lastRole = m.role;
      }

      // Get the message content length to calculate animation duration
      const messageToHide = session.messages.find((m) => m.id === messageId);
      const contentLength = messageToHide?.content?.length || 0;

      // Calculate animation duration: longer content = more time, but cap it
      // ~50 ticks at varying speed, minimum 500ms, maximum 2000ms
      const animationDuration = Math.min(2000, Math.max(500, contentLength * 2));

      // Animate hiding the old message, then delete after animation
      setMessageHiding(activeSessionId, messageId, true);
      setTimeout(() => {
        deleteMessage(activeSessionId, messageId);
      }, animationDuration);

      // Add new assistant message placeholder
      const assistantMessageId = addMessage(activeSessionId, 'assistant', '', selectedModel);
      currentMessageIdRef.current = assistantMessageId;

      setIsGenerating(true);
      playStartSound();
      setChatStatus('generating');

      // Find existing artifact for refinement
      const existingArtifactMessage = session.messages.find((m) => m.artifact);
      const existingArtifactContent = existingArtifactMessage?.artifact?.content;

      try {
        await sendMessage(apiMessages, selectedModel, session.settings, internetEnabled, searchProvider, searchMaxResults, false, artifactEnabled, existingArtifactContent);
      } catch (err) {
        console.error('Failed to regenerate message:', err);
        setIsGenerating(false);
        setChatStatus('idle');
        if (currentMessageIdRef.current && activeSessionId) {
          appendToMessage(
            activeSessionId,
            currentMessageIdRef.current,
            `**Error:** ${err instanceof Error ? err.message : 'Failed to regenerate'}`
          );
          setMessageStreaming(activeSessionId, currentMessageIdRef.current, false);
        }
        currentMessageIdRef.current = null;
      }
    },
    [activeSessionId, selectedModel, thinkingEnabled, internetEnabled, artifactEnabled, searchProvider, searchMaxResults, isGenerating, addMessage, deleteMessage, setMessageHiding, appendToMessage, setMessageStreaming, setIsGenerating, setChatStatus, sendMessage]
  );

  // Handle branching a message with a different model
  // Creates a new chat session with the user prompt and generates response with the selected model
  const handleBranch = useCallback(
    async (messageId: string, branchModel: string) => {
      if (!activeSessionId || isGenerating) return;

      const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
      if (!session) return;

      // Find the message
      const messageIndex = session.messages.findIndex((m) => m.id === messageId);
      if (messageIndex === -1) return;

      const message = session.messages[messageIndex];

      // Find the user message to branch from
      // If this is an assistant message, find the preceding user message
      let userMessage: typeof message | null = null;
      if (message.role === 'user') {
        userMessage = message;
      } else if (message.role === 'assistant') {
        // Find the user message that prompted this response
        for (let i = messageIndex - 1; i >= 0; i--) {
          if (session.messages[i].role === 'user') {
            userMessage = session.messages[i];
            break;
          }
        }
      }

      if (!userMessage) {
        console.error('Could not find user message to branch from');
        return;
      }

      // Create a new branched session with the same name as the original
      const createBranchedSession = useChatStore.getState().createBranchedSession;
      const newSessionId = createBranchedSession(activeSessionId, session.name, userMessage);

      // Load the new model
      setModelStatus('loading');
      setSelectedModel(branchModel);
      try {
        await loadModel(branchModel);
      } catch (err) {
        console.error('Failed to load model for branch:', err);
        setModelStatus('error');
        return;
      }

      // Now execute the request in the new session
      const newSession = useChatStore.getState().sessions.find((s) => s.id === newSessionId);
      if (!newSession) return;

      // Build API messages for the new session
      const apiMessages = buildApiMessages(newSession, BASE_SYSTEM_PROMPT);

      // Add assistant message placeholder for streaming
      const assistantMessageId = addMessage(newSessionId, 'assistant', '', branchModel);
      currentMessageIdRef.current = assistantMessageId;

      setIsGenerating(true);
      playStartSound();
      setChatStatus('generating');

      try {
        await sendMessage(apiMessages, branchModel, newSession.settings, internetEnabled, searchProvider, searchMaxResults, thinkingEnabled, artifactEnabled);
      } catch (err) {
        console.error('Failed to branch message:', err);
        setIsGenerating(false);
        setChatStatus('idle');
        if (currentMessageIdRef.current && newSessionId) {
          appendToMessage(
            newSessionId,
            currentMessageIdRef.current,
            `**Error:** ${err instanceof Error ? err.message : 'Failed to branch'}`
          );
          setMessageStreaming(newSessionId, currentMessageIdRef.current, false);
        }
        currentMessageIdRef.current = null;
      }
    },
    [activeSessionId, thinkingEnabled, internetEnabled, artifactEnabled, searchProvider, searchMaxResults, isGenerating, addMessage, appendToMessage, setMessageStreaming, setIsGenerating, setChatStatus, setModelStatus, setSelectedModel, loadModel, sendMessage, buildApiMessages]
  );

  // Handle editing a user message - set editing state (actual edit happens on send)
  const handleEdit = useCallback(
    (messageId: string) => {
      if (!activeSessionId || isGenerating) return;

      const session = useChatStore.getState().sessions.find((s) => s.id === activeSessionId);
      if (!session) return;

      const message = session.messages.find((m) => m.id === messageId);
      if (!message || message.role !== 'user') return;

      setEditingMessage({ id: messageId, content: message.content });
    },
    [activeSessionId, isGenerating]
  );

  // Cancel editing
  const handleEditCancel = useCallback(() => {
    setEditingMessage(null);
  }, []);

  // Handle model selection/loading
  const handleModelLoad = useCallback(
    (model: string) => {
      setModelStatus('loading');
      loadModel(model).catch((err) => {
        console.error('Failed to load model:', err);
        setModelStatus('error');
      });
    },
    [loadModel, setModelStatus]
  );

  const toggleSidebar = useCallback(() => {
    setSidebarOpen((prev) => !prev);
  }, []);

  // Handle starting the LLM server
  const handleStartServer = useCallback(async (model: string) => {
    setIsStartingServer(true);
    clearLlmServerLogs();
    try {
      await startLlmServer(model);
    } catch (err) {
      console.error('Failed to start LLM server:', err);
      setLlmServerStatus('error', err instanceof Error ? err.message : 'Failed to start server');
    } finally {
      setIsStartingServer(false);
    }
  }, [startLlmServer, setLlmServerStatus, clearLlmServerLogs]);

  return (
    <div
      className={`h-full relative transition-all duration-500 ease-out ${
        hasMounted ? 'opacity-100 scale-100' : 'opacity-0 scale-95'
      }`}
      style={{ backgroundColor: 'var(--color-base)' }}
    >
      {/* Floating sidebar */}
      <ChatSidebar isOpen={sidebarOpen} onToggle={toggleSidebar} />

      {/* Messages area - centered with max-width */}
      <div
        ref={scrollContainerRef}
        onScroll={handleScroll}
        className="h-full overflow-y-auto"
      >
        {/* Welcome view - animate out when messages appear */}
        <div
          className={`flex items-center justify-center h-full absolute inset-0 transition-all duration-500 ease-out ${
            messages.length === 0
              ? 'opacity-100 scale-100 pointer-events-auto'
              : 'opacity-0 scale-95 pointer-events-none'
          }`}
        >
          <ChatWelcome
            onSend={handleSend}
            onAbort={handleAbort}
            onModelLoad={handleModelLoad}
            onStartServer={handleStartServer}
            isStartingServer={isStartingServer}
            disabled={!selectedModel}
            isGenerating={isGenerating}
            isVisible={messages.length === 0}
          />
        </div>

        {/* Messages view - animate in when messages appear */}
        <div
          className={`max-w-3xl mx-auto px-6 transition-all duration-500 ease-out ${
            messages.length > 0
              ? 'opacity-100 translate-y-0'
              : 'opacity-0 translate-y-8 pointer-events-none'
          }`}
        >
          <div className="pt-40 pb-48">
            {(() => {
              const lastUserMessageIndex = messages.findLastIndex((m: ChatMessageType) => m.role === 'user');
              return messages.map((message, index) => (
                <ChatMessage
                  key={message.id}
                  message={message}
                  isLastMessage={index === messages.length - 1}
                  isLastUserMessage={index === lastUserMessageIndex}
                  onFollowUp={handleSend}
                  onRegenerate={handleRegenerate}
                  onEdit={handleEdit}
                  onBranch={handleBranch}
                  currentModel={selectedModel}
                />
              ));
            })()}
            <div ref={messagesEndRef} />
          </div>
        </div>
      </div>

      {/* Scroll to bottom button */}
      {showScrollButton && messages.length > 0 && (
        <div className="absolute bottom-28 left-1/2 -translate-x-1/2 z-10">
          <button
            onClick={() => scrollToBottom(true)}
            className="flex items-center justify-center w-10 h-10 rounded-full backdrop-blur-xl cursor-pointer transition-all duration-200 hover:scale-110 active:scale-95"
            style={{
              background: 'rgba(255, 255, 255, 0.12)',
              boxShadow: '0 4px 16px rgba(0, 0, 0, 0.3), inset 0 1px 0 rgba(255, 255, 255, 0.1)',
              color: 'var(--color-text-secondary)',
            }}
            title="Scroll to bottom"
          >
            <ArrowDown className="w-5 h-5" />
          </button>
        </div>
      )}

      {/* Floating input area - centered with max-width, animate in when messages appear */}
      <div
        className={`absolute bottom-0 left-0 right-0 px-6 pb-4 pointer-events-none transition-all duration-500 ease-out ${
          messages.length > 0
            ? 'opacity-100 translate-y-0'
            : 'opacity-0 translate-y-8'
        }`}
        style={{ overflow: 'visible' }}
      >
        <div className={`max-w-3xl mx-auto ${messages.length > 0 ? 'pointer-events-auto' : 'pointer-events-none'}`} style={{ overflow: 'visible' }}>
          {/* Show ServerStarter when LLM server is not ready */}
          {llmServerStatus !== 'ready' ? (
            <ServerStarter
              onStart={handleStartServer}
              isStarting={llmServerStatus === 'loading'}
            />
          ) : (
            <>
              <ChatInput
                onSend={handleSend}
                onAbort={handleAbort}
                onModelLoad={handleModelLoad}
                disabled={!selectedModel}
                isGenerating={isGenerating}
                isEmptyChat={messages.length === 0}
                editingMessage={editingMessage}
                onEditCancel={handleEditCancel}
              />
              <p
                className="text-xs text-center mt-2"
                style={{ color: 'var(--color-text-muted)' }}
              >
                Responses are generated by AI and may not always be accurate.
              </p>
            </>
          )}
        </div>
      </div>

      {/* LLM Server Controls - bottom right, aligned with input area */}
      <div className="absolute bottom-6 right-6 z-20">
        <LlmServerControls
          getLlmServerHealth={getLlmServerHealth}
          restartLlmServer={restartLlmServer}
          startLlmServer={startLlmServer}
          selectedModel={selectedModel}
          connected={wsConnected}
        />
      </div>
    </div>
  );
});

ChatView.displayName = 'ChatView';
