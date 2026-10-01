#lang racket

;;; ============================================================================
;;; tree-project.rkt —— 文件树投影：模型 → 普通 core 文档
;;; ============================================================================
;;;
;;; 输入是一份**只读**的 `tree-view`（编辑器 + 尺寸 + 已打开集合 + 视图表信息），
;;; 加上树模型；输出一份普通文档 + 新的模型（消费 goto）+ 光标。
;;;
;;; 这里没有任何全局状态、没有输入、没有文件操作 —— 纯投影。

(require "tree-model.rkt"
         "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt")

(provide (struct-out tree-view)
         tree-render
         tree-open-view-vid
         tree-structure-count*)

;; 投影所需的只读上下文。
(struct tree-view (editor editor-vid pane-w pane-h
                    opened open-views shown-views)
  #:transparent)

;; 用空格补到宽度 w（光标能在整行横向移动）。
(define (pad-to s w)
  (if (>= (string-length s) w) s
      (string-append s (make-string (- w (string-length s)) #\space))))

;;; ---------- 视图模式的行 ----------

;; 一个视图一行：当前编辑格视图前面加 ">"，后缀 L/C。
(define (view-line tv vid)
  (define ed (tree-view-editor tv))
  (define name (editor-view-document-name ed vid))
  (define active? (equal? vid (tree-view-editor-vid tv)))
  (format "~a~a  L~a C~a"
          (if active? ">" " ")
          name
          (editor-view-point-line ed vid)
          (editor-view-point-col ed vid)))

;; 视图行的 face：当前编辑格视图 / 显示在某窗格 / 当前没显示。
(define (view-face tv vid)
  (cond
    [(equal? vid (tree-view-editor-vid tv)) 'tree-view-active]
    [(memq vid (tree-view-shown-views tv)) 'tree-view]
    [else 'tree-view-hidden]))

;; 视图模式第 line 行对应哪个 vid。
(define (tree-open-view-vid open-views line)
  (and (>= line 0) (< line (length open-views)) (list-ref open-views line)))

;;; ---------- 结构行（按模式） ----------

(define (structure-lines* tv st)
  (case (tree-mode st)
    [(views) (for/list ([vid (in-list (tree-view-open-views tv))]) (view-line tv vid))]
    [else (tree-structure-lines st)]))

(define (line-faces* tv st)
  (case (tree-mode st)
    [(views) (for/list ([vid (in-list (tree-view-open-views tv))]) (view-face tv vid))]
    [else (for/list ([d.e (in-list (visible-of st))])
            (tree-struct-face (tree-view-opened tv) d.e))]))

(define (tree-structure-count* tv st) (length (structure-lines* tv st)))

;;; ---------- 投影 ----------

;; 整份重建：结构行（按模式上 face）+ 输入行；输入行钉到可见区最下面一行。
(define (tree-render tv st)
  (define struct-raw (structure-lines* tv st))
  (define faces (line-faces* tv st))
  (define rect-w (tree-view-pane-w tv))
  (define in (and (eq? (tree-mode st) 'files) (prompt-line st)))
  (define raw (if in (append struct-raw (list in)) struct-raw))
  ;; 统一宽度 = max(树宽, 最长行)：每行等长，光标可像平面一样横向移动。
  (define w (for/fold ([m rect-w]) ([l (in-list raw)]) (max m (string-length l))))
  (define ls (for/list ([l (in-list raw)]) (pad-to l w)))
  (define doc0 (document-open (if (null? ls) "" (string-join ls "\n"))))
  ;; 结构行按当前模式上 face；输入行用 'tree-prompt。
  (define doc
    (for/fold ([d doc0]) ([face (in-list faces)] [i (in-naturals)])
      (document-highlight-fill d i 0 i (string-length (list-ref ls i)) face)))
  (define doc* (if in
                   (document-highlight-fill doc (sub1 (length ls)) 0 (sub1 (length ls))
                                            (string-length (last ls)) 'tree-prompt)
                   doc))
  ;; 光标：输入行 → 行尾；goto → 目标行行首；否则保留 core 里的光标（#f）。
  (define cur
    (cond
      [in
       (define line (sub1 (length ls)))
       (define h (max 1 (tree-view-pane-h tv)))
       ;; 输入行 = 最后一行；视口顶到让最后一行恰在可见区底。
       (editor-view-set-top-line! (tree-view-editor tv) (tree-view-editor-vid tv)
                                  (max 0 (- line (sub1 h))))
       (point line (string-length in))]
      [(tree-goto st)
       (define line (tree-line-of st (tree-goto st)))
       (and line (point line 0))]
      [else #f]))
  (values doc* (struct-copy tree st [goto #f]) cur))
