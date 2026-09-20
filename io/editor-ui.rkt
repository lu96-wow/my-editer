#lang racket

;;; io/editor-ui.rkt —— TUI 后端共享的编辑器前端胶水
;;;
;;; 只放各个 TUI 接线都一样的「策略」，与布局/窗格数无关：
;;;   · face（语义）→ 终端样式
;;;   · 极简关键字高亮（用 patch 局部重标）
;;;   · 命令封装：编辑 / 撤销 / 重做后按 change-report 重标
;;;   · Ctrl 快捷键映射（key + mods → 动作符号）
;;;   · screen（run 序列）→ 终端字节的两段固定动作：画 runs、定位光标
;;;
;;; 布局、窗格、状态栏文字留在各自的 demo（io/tui.rkt、io/tui3.rkt）。

(require "../core/editor.rkt"
         ;; tui 也导出 key-event/resize-event 等事件结构体，与 core 同名；
         ;; 这里用 core 的，排除 tui 的。
         (except-in tui key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols
                    struct:resize-event))

(provide face-style
         highlight-range rehighlight apply-report
         edit-step undo-step redo-step
         ctrl-action
         draw-runs! draw-cursor!)

;;; ---------- face（语义）→ 终端样式 ----------

(define (face-style face)
  (case (hash-ref face 'face #f)
    [(keyword) 'info]
    [(comment) 'green]
    [(string)  'yellow]
    [(error)   'error]
    [else #f]))

;;; ---------- 一个极简高亮（使用方策略） ----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

;; 只扫 [fl,ll] 这些行
(define (syntax-segs ed bid fl ll)
  (append*
   (for/list ([line (in-range fl (add1 ll))])
     (define text (editor-buffer-line-ref ed bid line))
     (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
       (list line (car m) (cdr m) 'keyword)))))

;; 局部重标：在这几行上清旧写新（key='face）
(define (highlight-range ed bid fl ll)
  (editor-apply-patches ed bid (list (patch 'face fl ll (syntax-segs ed bid fl ll)))))

;; 打开时全量标一遍
(define (rehighlight ed)
  (define bid (editor-focused-buffer-id ed))
  (highlight-range ed bid 0 (sub1 (editor-buffer-line-count ed bid))))

;; 命令的第二返回值就是 change-report；有变化就按它给的行区间局部重标
(define (apply-report ed report)
  (if report
      (highlight-range ed (editor-focused-buffer-id ed)
                       (change-report-first-line report) (change-report-last-line report))
      ed))

;;; ---------- 命令封装：编辑 / 撤销 / 重做后按 change-report 重标 ----------

(define (edit-step ed op)
  (define-values (ed* r) (editor-edit ed op))
  (values (apply-report ed* r) r))

(define (undo-step ed)
  (define-values (ed* r) (editor-undo ed))
  (values (apply-report ed* r) r))

(define (redo-step ed)
  (define-values (ed* r) (editor-redo ed))
  (values (apply-report ed* r) r))

;;; ---------- Ctrl 快捷键 ----------

;; key + mods → 动作符号（'undo / 'redo / 'quit），其余 #f。
(define (ctrl-action key mods)
  (and (mods-ctrl? mods)
       (case key
         [(#\Z) 'undo]
         [(#\Y) 'redo]
         [(#\Q) 'quit]
         [else #f])))

;;; ---------- screen → 终端字节：画 runs、定位光标 ----------
;; 调用方提供 emit!（把一个字节串加入待写出列表）。

;; 画每行 runs（每段先移到它的显示列，再按 face 上色/直出）
(define (draw-runs! emit! scr)
  (for ([runs (in-vector (screen-row-runs scr))] [row (in-naturals)])
    (for ([r (in-list runs)])
      (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
      (define st (face-style (run-face r)))
      (emit! (if st (format-styled st (run-text r)) (format-content (run-text r)))))))

;; 光标按 core 算出的屏幕坐标定位（不可见则隐藏）
(define (draw-cursor! emit! scr)
  (define cr (screen-cursor-row scr))
  (define cc (screen-cursor-col scr))
  (if (>= cr 0)
      (begin (emit! (format-cursor-move (add1 cr) (add1 cc))) (emit! format-cursor-show))
      (emit! format-cursor-hide)))
