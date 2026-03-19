import React, { memo, useCallback, useRef, useState } from "react";
import { cva } from "class-variance-authority";
import { useAuiState, useScrollLock } from "@assistant-ui/react";
import { ChevronDown, Spinner } from "../icons.jsx";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "../ui/collapsible.jsx";
import { cn } from "../../lib/utils.js";

const ANIMATION_DURATION = 200;

const toolGroupVariants = cva("aui-tool-group-root group/tool-group w-full", {
    variants: {
        variant: {
            outline: "rounded-lg border py-3",
            ghost: "",
            muted: "rounded-lg border border-muted-foreground/30 bg-muted/30 py-3"
        }
    },
    defaultVariants: { variant: "outline" }
});

function ToolGroupRoot({
    className,
    variant,
    open: controlledOpen,
    onOpenChange: controlledOnOpenChange,
    defaultOpen = false,
    children,
    ...props
}) {
    const collapsibleRef = useRef(null);
    const [uncontrolledOpen, setUncontrolledOpen] = useState(defaultOpen);
    const lockScroll = useScrollLock(collapsibleRef, ANIMATION_DURATION);
    const isControlled = controlledOpen !== undefined;
    const isOpen = isControlled ? controlledOpen : uncontrolledOpen;

    const handleOpenChange = useCallback(
        (open) => {
            if (!open) lockScroll();
            if (!isControlled) setUncontrolledOpen(open);
            controlledOnOpenChange?.(open);
        },
        [lockScroll, isControlled, controlledOnOpenChange]
    );

    return (
        <Collapsible
            ref={collapsibleRef}
            data-variant={variant ?? "outline"}
            open={isOpen}
            onOpenChange={handleOpenChange}
            className={cn("group/tool-group-root", toolGroupVariants({ variant, className }))}
            style={{ "--animation-duration": `${ANIMATION_DURATION}ms` }}
            {...props}
        >
            {children}
        </Collapsible>
    );
}

function ToolGroupTrigger({ count, active = false, className, ...props }) {
    const label = `${count} tool ${count === 1 ? "call" : "calls"}`;

    return (
        <CollapsibleTrigger
            className={cn(
                "aui-tool-group-trigger group/trigger flex items-center gap-2 text-sm transition-colors",
                "group-data-[variant=outline]/tool-group-root:w-full group-data-[variant=outline]/tool-group-root:px-4",
                "group-data-[variant=muted]/tool-group-root:w-full group-data-[variant=muted]/tool-group-root:px-4",
                className
            )}
            {...props}
        >
            {active ? <Spinner className="aui-tool-group-trigger-loader size-4 shrink-0 animate-spin" /> : null}
            <span
                className={cn(
                    "aui-tool-group-trigger-label-wrapper relative inline-block text-left font-medium leading-none",
                    "group-data-[variant=outline]/tool-group-root:grow",
                    "group-data-[variant=muted]/tool-group-root:grow"
                )}
            >
                <span>{label}</span>
                {active ? (
                    <span
                        aria-hidden
                        className="aui-tool-group-trigger-shimmer shimmer pointer-events-none absolute inset-0 motion-reduce:animate-none"
                    >
                        {label}
                    </span>
                ) : null}
            </span>
            <ChevronDown
                className={cn(
                    "aui-tool-group-trigger-chevron size-4 shrink-0 transition-transform duration-(--animation-duration) ease-out",
                    "group-data-[state=closed]/trigger:-rotate-90",
                    "group-data-[state=open]/trigger:rotate-0"
                )}
            />
        </CollapsibleTrigger>
    );
}

function ToolGroupContent({ className, children, ...props }) {
    return (
        <CollapsibleContent
            className={cn(
                "aui-tool-group-content relative overflow-hidden text-sm outline-none",
                "group/collapsible-content ease-out",
                "data-[state=closed]:animate-collapsible-up data-[state=open]:animate-collapsible-down",
                "data-[state=closed]:fill-mode-forwards data-[state=closed]:pointer-events-none",
                "data-[state=open]:duration-(--animation-duration) data-[state=closed]:duration-(--animation-duration)",
                className
            )}
            {...props}
        >
            <div
                className={cn(
                    "mt-2 flex flex-col gap-2",
                    "group-data-[variant=outline]/tool-group-root:mt-3 group-data-[variant=outline]/tool-group-root:border-t group-data-[variant=outline]/tool-group-root:px-4 group-data-[variant=outline]/tool-group-root:pt-3",
                    "group-data-[variant=muted]/tool-group-root:mt-3 group-data-[variant=muted]/tool-group-root:border-t group-data-[variant=muted]/tool-group-root:px-4 group-data-[variant=muted]/tool-group-root:pt-3"
                )}
            >
                {children}
            </div>
        </CollapsibleContent>
    );
}

const ToolGroupImpl = ({ children, startIndex, endIndex }) => {
    const toolCount = endIndex - startIndex + 1;
    const isToolStreaming = useAuiState((s) => {
        if (s.message.status?.type !== "running") return false;
        const lastIndex = s.message.parts.length - 1;
        if (lastIndex < 0) return false;
        const lastType = s.message.parts[lastIndex]?.type;
        if (lastType !== "tool-call") return false;
        return lastIndex >= startIndex && lastIndex <= endIndex;
    });

    return (
        <ToolGroupRoot defaultOpen={isToolStreaming}>
            <ToolGroupTrigger count={toolCount} active={isToolStreaming} />
            <ToolGroupContent>{children}</ToolGroupContent>
        </ToolGroupRoot>
    );
};

export const ToolGroup = memo(ToolGroupImpl);
ToolGroup.displayName = "ToolGroup";
ToolGroup.Root = ToolGroupRoot;
ToolGroup.Trigger = ToolGroupTrigger;
ToolGroup.Content = ToolGroupContent;
