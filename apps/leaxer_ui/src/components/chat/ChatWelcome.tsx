import { memo, useMemo } from 'react';
import suggestionsData from '@/data/chatSuggestions.json';
import welcomeTitlesData from '@/data/welcomeTitles.json';
import { ChatInput } from './ChatInput';
import { ServerStarter } from './ServerStarter';
import { useChatStore } from '@/stores/chatStore';
import type { ChatAttachment } from '@/types/chat';

interface ChatWelcomeProps {
  onSend?: (message: string, attachments?: ChatAttachment[]) => void;
  onAbort?: () => void;
  onModelLoad?: (model: string) => void;
  onStartServer?: (model: string) => Promise<void>;
  isStartingServer?: boolean;
  disabled?: boolean;
  isGenerating?: boolean;
  isVisible?: boolean;
}

// Randomly select n items from an array
function getRandomSuggestions(count: number): string[] {
  const shuffled = [...suggestionsData.suggestions].sort(() => Math.random() - 0.5);
  return shuffled.slice(0, count);
}

// Get a random welcome title
function getRandomWelcomeTitle(): string {
  const index = Math.floor(Math.random() * welcomeTitlesData.titles.length);
  return welcomeTitlesData.titles[index];
}

export const ChatWelcome = memo(({ onSend, onAbort, onModelLoad, onStartServer, isStartingServer: _isStartingServer = false, disabled, isGenerating, isVisible }: ChatWelcomeProps) => {
  // Get random welcome title, memoized so it doesn't change on re-render
  const welcomeTitle = useMemo(() => getRandomWelcomeTitle(), []);
  // Get 3 random suggestions, memoized so they don't change on re-render
  const suggestions = useMemo(() => getRandomSuggestions(3), []);

  // LLM server state
  const llmServerStatus = useChatStore((s) => s.llmServerStatus);

  // Show ServerStarter when LLM server is not ready
  const showServerStarter = llmServerStatus !== 'ready';

  return (
    <div className="flex flex-col items-center justify-center h-full text-center w-full max-w-2xl mx-auto px-6">
      {/* Logo */}
      <div className="mb-6">
        <LeaxerLogo className="w-20 h-20" />
      </div>

      {/* Subtitle */}
      <p
        className="text-xl font-bold mb-8"
        style={{ color: 'var(--color-text-secondary)', fontFamily: 'Geist Mono, monospace' }}
      >
        {welcomeTitle}
      </p>

      {/* ChatInput or ServerStarter - centered */}
      <div className="w-full mb-6" style={{ overflow: 'visible' }}>
        {showServerStarter && onStartServer ? (
          <ServerStarter
            onStart={onStartServer}
            isStarting={llmServerStatus === 'loading'}
          />
        ) : (
          <ChatInput
            onSend={onSend!}
            onAbort={onAbort}
            onModelLoad={onModelLoad}
            disabled={disabled}
            isGenerating={isGenerating}
            autoFocus
            focusTrigger={isVisible}
            isEmptyChat
          />
        )}
      </div>

      {/* Suggestions - only show when server is ready */}
      {!showServerStarter && (
        <>
          <p
            className="text-xs mb-2"
            style={{ color: 'var(--color-text-muted)' }}
          >
            Or try one of these
          </p>
          <div className="flex flex-wrap justify-center gap-2 w-full">
            {suggestions.map((suggestion, index) => (
              <SuggestionCard
                key={index}
                text={suggestion}
                onClick={() => onSend?.(suggestion)}
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
});

ChatWelcome.displayName = 'ChatWelcome';

interface SuggestionCardProps {
  text: string;
  onClick?: () => void;
}

const SuggestionCard = memo(({ text, onClick }: SuggestionCardProps) => (
  <button
    onClick={onClick}
    className="px-3 py-1.5 rounded-full text-xs transition-all duration-200 cursor-pointer hover:bg-white/10"
    style={{
      background: 'rgba(255, 255, 255, 0.06)',
      color: 'var(--color-text-secondary)',
    }}
  >
    {text}
  </button>
));

SuggestionCard.displayName = 'SuggestionCard';

// Predefined gradient combinations from brand guide
const logoGradients = [
  // Pink → Blue → Cyan
  { colors: ['#F18DF2', '#275AF2', '#00D9FF'] },
  // Magenta → Orange → Peach
  { colors: ['#E85A9C', '#F5A623', '#FFCC80'] },
  // Pink/Magenta → Purple
  { colors: ['#F22FB0', '#8B5CF6', '#7C3AED'] },
  // Pink → Blue → Teal
  { colors: ['#F22FB0', '#275AF2', '#06B6D4'] },
  // Purple → Cyan → Blue
  { colors: ['#7C3AED', '#06B6D4', '#3B82F6'] },
  // Magenta → Purple → Teal/Green
  { colors: ['#F472B6', '#8B5CF6', '#10B981'] },
];

function getRandomGradient() {
  return logoGradients[Math.floor(Math.random() * logoGradients.length)];
}

/**
 * Leaxer logo with animated gradient and playful idle animations.
 */
const LeaxerLogo = memo(({ className }: { className?: string }) => {
  const gradient = useMemo(() => getRandomGradient(), []);
  const [c1, c2, c3] = gradient.colors;

  return (
    <div className={`${className} leaxer-logo-idle`}>
      <style>
        {`
          .leaxer-logo-idle {
            animation: leaxerIdle 12s ease-in-out infinite;
          }

          @keyframes leaxerIdle {
            0%, 100% {
              transform: scale(1) rotate(0deg);
            }
            8% {
              transform: scale(1) rotate(0deg);
            }
            /* Gentle bounce */
            10% {
              transform: scale(1.08, 0.94) translateY(3px);
            }
            12% {
              transform: scale(0.95, 1.06) translateY(-5px);
            }
            14% {
              transform: scale(1.03, 0.98) translateY(1px);
            }
            16% {
              transform: scale(1) translateY(0);
            }
            /* Rest */
            30% {
              transform: scale(1) rotate(0deg);
            }
            /* Soft squish */
            32% {
              transform: scale(1.06, 0.95);
            }
            35% {
              transform: scale(0.97, 1.04);
            }
            38% {
              transform: scale(1);
            }
            /* Rest */
            50% {
              transform: scale(1) rotate(0deg);
            }
            /* Gentle tilt */
            52% {
              transform: rotate(-4deg) scale(1.02);
            }
            56% {
              transform: rotate(3deg) scale(1.02);
            }
            60% {
              transform: rotate(0deg) scale(1);
            }
            /* Rest */
            72% {
              transform: scale(1);
            }
            /* Soft pulse */
            74% {
              transform: scale(1.06);
            }
            78% {
              transform: scale(0.98);
            }
            82% {
              transform: scale(1.02);
            }
            85% {
              transform: scale(1);
            }
          }
        `}
      </style>
      <svg
        className="w-full h-full"
        viewBox="0 0 511 512"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <radialGradient
            id="welcomeGradient"
            cx="0"
            cy="0"
            r="1"
            gradientUnits="userSpaceOnUse"
            gradientTransform="translate(0 512) rotate(-45) scale(782 780)"
          >
            <stop offset="0%" stopColor={c1}>
              <animate
                attributeName="stop-color"
                values={`${c1};${c2};${c3};${c1}`}
                dur="4s"
                repeatCount="indefinite"
              />
            </stop>
            <stop offset="50%" stopColor={c2}>
              <animate
                attributeName="stop-color"
                values={`${c2};${c3};${c1};${c2}`}
                dur="4s"
                repeatCount="indefinite"
              />
            </stop>
            <stop offset="100%" stopColor={c3}>
              <animate
                attributeName="stop-color"
                values={`${c3};${c1};${c2};${c3}`}
                dur="4s"
                repeatCount="indefinite"
              />
            </stop>
          </radialGradient>
        </defs>
        <path
          d="M416.304 0L94.8107 2.81609e-05C-9.11684 3.72643e-05 -37.1644 143.461 59.0821 182.749L213.662 245.85C237.275 255.489 256.011 274.261 265.631 297.92L328.608 452.802C367.819 549.237 511 521.135 511 417.004L511 94.8809C511 42.4796 468.603 -4.58107e-06 416.304 0Z"
          fill="url(#welcomeGradient)"
        />
      </svg>
    </div>
  );
});

LeaxerLogo.displayName = 'LeaxerLogo';
