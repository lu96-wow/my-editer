#lang racket

;;; api.rkt —— core 层对外的唯一入口（门面 / 纯转发层）
;;;
;;; core 内部各模块按依赖互相 require，属于「实现细节」；对外只暴露这一个模块。
;;; 使用方一律 (require "core/api.rkt")，不要直接 require core/text/* 或 core/view/*。
;;;
;;; 本文件只做转发（require + all-from-out / except-out），不引入任何实现：
;;; 与「数据 → lambda → 数据」一致，门面本身零逻辑。

(require "text/cursor.rkt"
         "text/content.rkt"
         "text/buffer.rkt"
         "text/edit.rkt"
         "text/marker.rkt"
         "text/overlay.rkt"
         "text/patch.rkt"
         "text/properties.rkt"
         "view/events.rkt"
         "view/width.rkt"
         "view/render.rkt"
         "view/screen.rkt"
         "view/window.rkt"
         "view/view.rkt"
         "view/project.rkt")

(provide
 ;; ---- text 层 ----
 (all-from-out "text/cursor.rkt")
 (all-from-out "text/content.rkt")
 ;; buffer.rkt 与 content.rkt 都导出 edit-desc（buffer 只是转发）。
 ;; 去重：edit-desc 及其访问器 / 位置映射以 content.rkt（结构定义处）为唯一来源。
 (except-out (all-from-out "text/buffer.rkt")
             edit-desc
             edit-desc?
             edit-desc-s-line
             edit-desc-s-col
             edit-desc-e-line
             edit-desc-e-col
             edit-desc-new-text
             edit-desc-after-position)
 (all-from-out "text/edit.rkt")
 (all-from-out "text/marker.rkt")
 (all-from-out "text/overlay.rkt")
 (all-from-out "text/patch.rkt")
 (all-from-out "text/properties.rkt")
 ;; ---- view 层 ----
 (all-from-out "view/events.rkt")
 (all-from-out "view/width.rkt")
 (all-from-out "view/render.rkt")
 (all-from-out "view/screen.rkt")
 (all-from-out "view/window.rkt")
 (all-from-out "view/view.rkt")
 (all-from-out "view/project.rkt"))

;;; ---------- 冒烟测试 ----------

(module+ test
  (require rackunit)
  ;; 门面转发后，跨 text / view 的核心绑定应可直接使用。
  (define b (buffer-open "hello\nworld"))
  (check-equal? (buffer->string b) "hello\nworld")
  (check-equal? (buffer-line-count b) 2)

  (define w (window-open b 2 10))
  (check-equal? (window-point w) (cursor 0 0))
  (check-equal? (screen-rows (window->screen w)) 2)

  ;; 一个跨层编辑闭环：插入字符 → 窗口光标推进 → 渲染出新文本
  (define-values (w2 desc) (window-insert w #\X))
  (check-equal? (buffer->string (window-buffer w2)) "Xhello\nworld")
  (check-equal? desc (edit-desc 0 0 0 0 "X"))
  (check-equal? (window-point w2) (cursor 0 1))

  (displayln "api.rkt: all tests passed"))
