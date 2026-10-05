#lang racket

(require "../../core/text/base/line.rkt"
         "../base/face.rkt"
         "api.rkt"
         "lex.rkt")

;;; lab/plugin/words.rkt —— 词着色：每个词一种颜色（内置插件）
;;;
;;; 每个标识符 token → (palette-color 'word (equal-hash-code 词))，
;;; 所以**同一个词永远同一个颜色**（跨版本 / undo 也稳定，hash 是确定性的），
;;; 不同词大概率不同色（色板取模，可能撞色）。
;;;
;;; 无状态：open/change 都整篇重扫（词着色本来就不需要增量维护）。

(provide word-plugin)

(define (word-fills text)
  (for/list ([tok (in-list (scan-words text))])
    (match-define (list ln s e w) tok)
    (list ln s ln e (palette-color 'word (equal-hash-code w)))))

(define (word-open text _path) (values #f (word-fills text)))

(define (word-change _state _edits lines path)
  (word-open (lines->string (vector->list lines)) path))

(define word-plugin
  (plugin 'words word-open word-change))
