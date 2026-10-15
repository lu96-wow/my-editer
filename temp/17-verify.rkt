#lang racket
;;; 17 —— edit-tui × core 验证 demo：布局 + 增量渲染
;;;
;;; core 建 buffer / view / panel，render-display-patch 出 screen + piece；
;;; edit-tui/core-render 把 piece 画成 racket-tui 序列。
;;;
;;; 默认（headless）：跑一串操作（编辑 / 移光标 / 滚 / 移浮窗 / 改边框），
;;;   每步比对「增量屏 == 全量屏」，打印帧 + 差分 piece 数 + tui 字节数。
;;; 带任意参数：真终端交互（racket-tui），按键触发同样的操作。
;;;
;;;   racket temp/17-verify.rkt          # 校验
;;;   racket temp/17-verify.rkt tui      # 交互

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"        ; require 即装样式（face 符号 → 颜色）
         "../edit-tui/core-render/main.rkt") ; render-pieces（piece → tui 序列）

(define W 72)
(define H 14)

;;; ---------- 内容 ----------

(define tree-b  (make-buffer "src/\n  main.rkt\n  util.rkt\n  panel.rkt\n  border.rkt\nREADME.md" "*tree*"))
(define doc-b   (make-buffer "(define (f x)\n  ;; doc\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define float-b (make-buffer "float\non top\n(deep 10)\n" "*float*"))

(define tree-v  (buffer-add-view! tree-b #:line-numbers? #t))
(define doc-v   (buffer-add-view! doc-b #:line-numbers? #t))
(define float-v (buffer-add-view! float-b))

;;; ---------- 布局（可变状态：浮窗位置 / doc 上边框 / 光标 / 滚动）----------

(define float-xs (list 30 34 38 42 38 34))
(define fx (box 0))
(define doc-top? (box #t))
(define cur-line (box 0))
(define top-line (box 0))

(define (panels)
  (list (make-panel tree-v (rect 0 0 20 H) borders-all)
        (make-panel doc-v (rect 20 0 (- W 20) H)
                    (if (unbox doc-top?) '(up down right) '(down right)))
        (make-panel float-v (rect (list-ref float-xs (unbox fx)) 3 24 7) borders-all
                    #:deep 10 #:face 'float-border)))

(define (sync!) (panels-sync! (panels)))

;;; ---------- 渲染：增量 cache → (screen, render pieces, selection pieces) ----------

(define cache #f)
(define (frame)
  (define p (panels))
  (sync!)
  (define-values (c r s) (render-display-patch p doc-v W H cache))
  (set! cache c)
  (values (render-cache-screen c) r s))

;;; ---------- headless 校验 ----------

(define (verify! label)
  (define p (panels))
  (sync!)
  (define-values (c r s) (render-display-patch p doc-v W H cache))
  (set! cache c)
  (define scr (render-cache-screen c))
  (define inc (screen->string scr))
  (define full (screen->string (render-display p doc-v W H)))
  (unless (equal? inc full) (error 'verify "~a：增量屏 != 全量屏" label))
  (define bytes (render-pieces (append r s)))
  ;; 定位（单焦点）：焦点光标 = 合成屏主光标；doc panel 的可见光标位置
  (define pc (screen-primary-cursor scr))
  (define doc-panel (cadr p))
  (define-values (fr fc) (panel-cursor-position/visible scr doc-panel))
  (printf "── ~a ──  piece: render=~a selection=~a / tui bytes=~a / 焦点光标=~a / doc可见=~a  ✓\n~a\n\n"
          label (length r) (length s) (bytes-length bytes)
          (if pc (list (cursor-row pc) (cursor-column pc)) '(#f #f))
          (if fr (list fr fc) #f)
          inc))

(define (run-verify!)
  (verify! "首帧（全量）")
  (void (buffer-edit! doc-b doc-v (op-type ";; edited\n")))
  (verify! "编辑 doc")
  (set-box! cur-line 3) (view-set-point! doc-v (point (unbox cur-line) 0))
  (verify! "移光标")
  (set-box! top-line 20) (view-scroll-to-line! doc-v (unbox top-line))
  (verify! "滚动 doc（多行变，走整体合成）")
  (set-box! fx 2)
  (verify! "移浮窗（布局变）")
  (set-box! doc-top? #f)
  (verify! "去 doc 上边框（布局变）")
  (displayln "全部 OK：布局 + 增量渲染一致"))

;;; ---------- racket-tui 交互 ----------

(define (draw!)
  (define-values (scr r s) (frame))
  (put-bytes (bytes-append (render-clear) (render-pieces (append r s))))
  (put-bytes (format-cursor-move H 1))
  (put-string "e:编辑  c:移光标  s:滚动  f:移浮窗  b:边框  q:退出")
  (flush!))

(define (run-tui!)
  (with-tui
   (λ ()
     (cursor-hide)
     (draw!)
     (let loop ()
       (define ev (read-event))
       (cond
         [(resize-event? ev) (draw!) (loop)]
         [(null-event? ev) (loop)]
         [(key-event? ev)
          (case (key-event-key ev)
            [(#\q) (void)]
            [(#\e) (void (buffer-edit! doc-b doc-v (op-type "x"))) (draw!) (loop)]
            [(#\c) (set-box! cur-line (modulo (add1 (unbox cur-line)) 10))
                   (view-set-point! doc-v (point (unbox cur-line) 0)) (draw!) (loop)]
            [(#\s) (set-box! top-line (modulo (+ (unbox top-line) 5) 100))
                   (view-scroll-to-line! doc-v (unbox top-line)) (draw!) (loop)]
            [(#\f) (set-box! fx (modulo (add1 (unbox fx)) (length float-xs))) (draw!) (loop)]
            [(#\b) (set-box! doc-top? (not (unbox doc-top?))) (draw!) (loop)]
            [else (draw!) (loop)])]
         [else (loop)])))))

(module+ main
  (if (pair? (current-command-line-arguments))
      (run-tui!)
      (run-verify!)))
