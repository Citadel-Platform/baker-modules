# Firebase auth bridge

Turns a Firebase sign-in into the identity every Platform API call
carries, and keeps the token fresh without the calling code knowing it happened.

It never stores a token anywhere a page can read it back, and it does not decide
what anybody may do: authority comes from Palisade, resolved per project, and a
bridge that cached a permission would be a second answer to a question that has
one.
