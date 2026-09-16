#lang racket

;;; plugin/edit-api.rkt —— 编辑能力 SDK 契约（只 re-export，无实现）
;;;
;;; 与 plugin/annotate-api.rkt（标注/只读面）相对，这是「改 buffer 内容」的编辑面，覆盖：
;;;   slot #2a 编辑插件  : buffer (or/c #f edit-desc) -> (listof edit-desc)
;;;   slot #2b 编辑策略  : window-commands -> window-commands（命令装饰器）
;;;
;;; 设计要点：
;;;   - 编辑 = 一次/一批 edit-desc（统一 splice），改 content → 产生 dirty；
;;;   - 编辑插件只产出 edit-desc，应用与同步由框架（run-edit-plugins / edit-active）做；
;;;   - 编辑策略是光标敏感的命令装饰器，用 compose-edit-strategies 组合；
;;;   - 编辑与标注正交：编辑产生 dirty → 标注插件（plugin/annotate-api.rkt）自动消费。

(require "../core/text/buffer.rkt"     ; buffer-* 编辑原语 + edit-desc 结构
         "../core/text/content.rkt"    ; edit-desc-map-position
         "../core/text/cursor.rkt"
         "../core/text/edit.rkt"       ; buffer-apply-edits / edit-descs-map-position
         "../core/view/window.rkt"
         "../core/view/frame.rkt"
         "../core/view/events.rkt"
         "../framework/slots.rkt"
         "../framework/framework.rkt"
         "../reference/commands.rkt")  ; edit-active（编辑管线）

(provide
 ;; ---------- 编辑产物 ----------
 edit-desc
 edit-desc-s-line edit-desc-s-col edit-desc-e-line edit-desc-e-col edit-desc-new-text
 edit-desc-after-position edit-desc-map-position
 buffer-apply-edits
 edit-descs-map-position

 ;; ---------- buffer 编辑原语（显式位置，返回 (values buffer edit-desc)）----------
 buffer-splice buffer-insert buffer-insert-text
 buffer-newline buffer-backspace buffer-delete

 ;; ---------- buffer 只读 ----------
 buffer-open
 buffer-line-count buffer-line-ref buffer->string buffer->lines
 buffer-dirty buffer-tick buffer-gap
 buffer-get-text-property

 ;; ---------- 位置（0-based 字符索引）----------
 cursor cursor-line cursor-col
 cursor<? cursor=? cursor<=? cursor-clamp

 ;; ---------- window（编辑策略用：编辑 + 光标 + 只读）----------
 window-insert window-insert-text window-newline window-backspace window-delete
 window-set-point window-set-buffer window-goto
 window-buffer window-point window-mode

 ;; ---------- frame（编辑策略读 active 窗口 / 构造测试）----------
 frame-open frame-active frame-active-window frame-window
 frame-set-window frame-window-count
 frame-edit-active frame-sync-buffer frame-ensure-active

 ;; ---------- 命令 / 组合 / 管线 ----------
 window-commands window-commands-on-text window-commands-on-key
 compose-edit-strategies
 edit-active

 ;; ---------- config ----------
 make-config config-plugins config-edit-plugins config-theme

 ;; ---------- 事件（编辑策略拦截用）----------
 text-event text-event-text
 key-event key-event-key
 modifiers modifiers-control modifiers-alt modifiers-shift modifiers-meta

 ;; ---------- 编辑插件声明与运行 ----------
 edit-plugin-spec run-edit-plugins run-edit-plugins-init)
