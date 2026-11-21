// Notcher — web rendition of the NotchCore design kit. Each component is a function that returns an HTML string
// styled by bundle.css; slots (children, trailing, leading) take HTML strings. Mirrors Sources/NotchCore/Design.

export type TintRole = 'primary' | 'secondary' | 'accent' | 'success' | 'warning';
export type NotchTextStyle = 'title' | 'body' | 'caption' | 'label' | 'numeric' | 'display';
export type NotchState = 'closed' | 'hover' | 'activity' | 'drop' | 'expanded';

export interface NotchSurfaceProps {
  /** Which of the five states to draw. Default 'closed'. */
  state?: NotchState;
  /** Which page the expanded panel shows. Default 'home'. */
  page?: 'home' | 'clipboard';
  /** Wings, band and content, as HTML. */
  children?: string;
}

export interface LiveActivityProps {
  /** Left wing glyph, rendered at roughly 18 pt. */
  leading: string;
  /** Right wing glyph, optional. Keep text to about 6 characters. */
  trailing?: string;
}

export interface GlassCardProps {
  /** Children, stacked vertically and leading-aligned. */
  children?: string;
  /** Accent wash and outline: an active drop target or a selected item. */
  highlighted?: boolean;
  className?: string;
  style?: string;
}

export interface GlassButtonProps {
  /** One or two words, sentence case. */
  title: string;
  /** Icon name. */
  symbol?: string;
  /** 'accent' tints the glass. Default 'standard'. */
  prominence?: 'standard' | 'accent';
}

export interface GlassIconButtonProps {
  /** Icon name. */
  symbol: string;
  /** Accessibility label and tooltip. Required. */
  label: string;
  /** Interactive glass, or borderless with a hover fill. Default 'glass'. */
  kind?: 'glass' | 'plain';
  /** Diameter in px. Default 28 (glass) or 24 (plain). */
  size?: number;
  tint?: TintRole;
}

export interface RowButtonProps {
  /** The row's label, normally a ResultRow. */
  children: string;
}

export interface SectionHeaderProps {
  /** One or two words in normal case; rendered uppercase. */
  title: string;
  /** Icon name, drawn at 10 px in text-tertiary. */
  symbol?: string;
  /** One small accessory, as HTML. */
  trailing?: string;
}

export interface ResultRowProps {
  /** One line, truncated in the middle. */
  title: string;
  /** One line in caption. */
  detail?: string;
  /** A short figure in numeric. */
  trailing?: string;
  trailingTint?: TintRole;
  /** Image URL for the 26 px thumbnail. */
  thumbnail?: string;
  /** Icon name used when there is no thumbnail. Default 'doc'. */
  symbol?: string;
  symbolTint?: TintRole;
  /** Replaces the thumbnail with HTML, such as a ProgressRing. */
  leading?: string;
}

export interface EmptyStateProps {
  /** Icon name, drawn at 18 px. */
  symbol: string;
  /** What to do next. */
  title: string;
  /** Optional hint, at most two lines. */
  message?: string;
}

export interface ProgressRingProps {
  /** 0 to 1, clamped. */
  progress: number;
  /** Diameter in px. Default 16. */
  size?: number;
  /** Default 'accent'. */
  tint?: TintRole;
}

export interface StatusDotProps {
  tint: TintRole;
  /** True only when the user has to act. */
  pulsing?: boolean;
}

export interface EqualizerBarsProps {
  playing: boolean;
  /** Default 'primary'. */
  tint?: TintRole;
}

export interface CountdownTextProps {
  /** The date to count down to. */
  to?: Date | string | number;
  /** Seconds from now, instead of `to`. */
  seconds?: number;
  /** Default 'numeric'. */
  style?: NotchTextStyle;
  tint?: TintRole;
}
