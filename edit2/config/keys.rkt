#lang racket

;;; config/keys.rkt —— 命令表（**纯数据**，不 require 任何实现）
;;;
;;; entry = (binding scope op ...)
;;;   binding : (key k mod ...) | (cursor kind button) | (text)
;;;   scope   : always | editor | float | prompt | (panel name)
;;;   op      : core 原语（见 core/step.rkt run-ops）
;;;
;;; 加/改一条绑定 = 改这里一行数据；用已有原语组合出新行为，也能这样写。

(provide key-table)

(define key-table
  '(
    ;; ---------- 指针 / 光标 ----------
    ((cursor press left)   always (pointer))
    ((cursor scroll up)    always (scroll -1))
    ((cursor scroll down)  always (scroll 1))

    ;; ---------- 全局 ----------
    ((key q ctrl)  always (quit))
    ((key d ctrl)  editor (close-view))
    ((key s ctrl)  always (save))
    ((key b ctrl)  always (region-toggle sidebar))
    ((key l ctrl)  always (region-toggle log))
    ((key h ctrl)  always (float-open help))
    ((key e alt)   always (focus editor))
    ((key n alt)   always (focus (cycle 1)))
    ((key p alt)   always (focus (cycle -1)))
    ((key escape)  float  (float-close))
    ((key tab)     float  (float-cycle))

    ;; ---------- 侧栏成员（区域显示即聚焦） ----------
    ((key t alt)   always (region-show sidebar tree))
    ((key b alt)   always (region-show sidebar buffers))

    ;; ---------- 面板选择 = 文档导航（一切皆 document） ----------
    ((key down)  (panel tree)    (move down))
    ((key up)    (panel tree)    (move up))
    ((key right) (panel tree)    (activate))
    ((key left)  (panel tree)    (collapse))
    ((key enter) (panel tree)    (activate))
    ((key down)  (panel buffers) (move down))
    ((key up)    (panel buffers) (move up))
    ((key enter) (panel buffers) (activate))

    ;; ---------- 编辑 ----------
    ((key z ctrl) editor (undo))
    ((key y ctrl) editor (redo))
    ((key a ctrl) editor (select-all))
    ((key c ctrl) editor (copy))
    ((key x ctrl) editor (cut))
    ((key v ctrl) editor (paste))
    ((key w ctrl) editor (split))
    ((key enter)     editor (insert "\n"))
    ((key backspace) editor (delete-back))
    ((key delete)    editor (delete))
    ((key left)  editor (move left))
    ((key right) editor (move right))
    ((key up)    editor (move up))
    ((key down)  editor (move down))
    ((key home)  editor (move home))
    ((key end)   editor (move end))
    ((text)      editor (insert-event-text))))
