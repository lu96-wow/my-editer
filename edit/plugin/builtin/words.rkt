#lang racket

;;; edit/plugin/builtin/words.rkt —— 词高亮插件（dabbrev 式）
;;;
;;; 颜色来自一张**持久表** word → 色号（state，由 session 按 did 保存、逐次传入）：
;;;   · 首次见到某个词 → 取「下一个号」(= 表里已有词数)，插进表；
;;;   · 以后每次见到 → 用表里的号。
;;; 于是同词同色、不同词不同号；表只增不减，所以插新词也不会让后面的词变色。
;;; 跳过正在输入的活动词（点前的词），免得边打边换色。

(require "../../plugin/registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt")

(provide word-plugin)

;; tokens 按出现顺序；skip = 活动 token | #f；map = 旧表。→ (values 新表 fills)
(define (assign-fills tokens skip map)
  (define out (make-hash))
  (define next (box (hash-count map)))
  (define fills
    (for/list ([tok (in-list tokens)]
               #:unless (and skip (= (car tok) (car skip)) (= (cadr tok) (cadr skip))))
      (match-define (list ln s e w) tok)
      (define idx
        (cond [(hash-ref map w #f)]          ; 见过 → 沿用（0 也是真值）
              [(hash-ref out w #f)]          ; 本趟里前面出现过
              [else (begin0 (unbox next) (set-box! next (add1 (unbox next))))]))
      (hash-set! out w idx)
      (list ln s ln e (palette-color 'word idx))))
  (define new-map (hash-copy map))
  (for ([(w i) (in-hash out)]) (hash-set! new-map w i))
  (values new-map fills))

(define (word-run state ctx)
  (define toks (scan-words (doc-ctx-text ctx)))
  (assign-fills toks (active-token toks (doc-ctx-point ctx)) (or state (hash))))

(define word-plugin
  (doc-plugin 'words racket-applies? word-run))
